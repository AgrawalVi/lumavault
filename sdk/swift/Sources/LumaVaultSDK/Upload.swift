import Connect
import Foundation
import UniformTypeIdentifiers

/// Uploads a file in one call: plan locally, ask which chunks are missing, upload only those,
/// then commit. CommitObject is never retried here; a lost response would create a duplicate.
func uploadFile(
    rpc: Lumavault_V1_StorageServiceClient,
    dataPlane: DataPlane,
    fileURL: URL,
    namespace: Namespace,
    filename: String?,
    mimeType: String?,
    concurrency: Int,
    progress: (@Sendable (UploadProgress) -> Void)?
) async throws -> ObjectMetadata {
    let plan = try planChunks(fileURL: fileURL) { loaded, total in
        progress?(UploadProgress(phase: .hashing, loaded: loaded, total: total))
    }
    try Task.checkCancellation()

    var hasRequest = Lumavault_V1_HasChunksRequest()
    hasRequest.chunkHashes = plan.chunkHashes
    let missing = Set(try await rpc.hasChunks(request: hasRequest).unwrap().missingChunkHashes)
    let toSend = uniqueChunkIndexes(plan).filter { missing.contains(plan.chunkHashes[$0]) }

    // Chunks the gateway already has count as loaded straight away.
    let tally = LoadedTally(plan.sizeBytes - toSend.reduce(0) { $0 + chunkLength(plan, $1) })
    progress?(UploadProgress(phase: .uploading, loaded: tally.value, total: plan.sizeBytes))

    try await withThrowingTaskGroup(of: Int.self) { group in
        var next = 0
        func startNext() {
            guard next < toSend.count else { return }
            let index = toSend[next]
            next += 1
            group.addTask {
                try await dataPlane.putChunk(
                    sha256: plan.chunkHashes[index],
                    file: fileURL,
                    offset: UInt64(index) * UInt64(plan.chunkSizeBytes),
                    length: Int(chunkLength(plan, index))
                )
                return index
            }
        }
        for _ in 0..<max(1, concurrency) { startNext() }
        while let index = try await group.next() {
            let loaded = tally.add(chunkLength(plan, index))
            progress?(UploadProgress(phase: .uploading, loaded: loaded, total: plan.sizeBytes))
            startNext()
        }
    }

    var commit = Lumavault_V1_CommitObjectRequest()
    commit.namespace = namespace
    commit.filename = filename ?? fileURL.lastPathComponent
    commit.mimeType = mimeType ?? UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? ""
    commit.sizeBytes = plan.sizeBytes
    commit.chunkSizeBytes = UInt32(plan.chunkSizeBytes)
    commit.sha256Digest = plan.sha256Digest
    commit.chunkHashes = plan.chunkHashes
    commit.skipDedup = true
    let response = try await rpc.commitObject(request: commit).unwrap()
    guard response.hasObject else {
        throw ConnectError(code: .internalError, message: "gateway returned no object for CommitObject")
    }
    return response.object
}

// A file can repeat the same chunk, such as runs of zeros; send each distinct hash once.
private func uniqueChunkIndexes(_ plan: ChunkPlan) -> [Int] {
    var seen = Set<String>()
    return plan.chunkHashes.indices.filter { seen.insert(plan.chunkHashes[$0]).inserted }
}

private func chunkLength(_ plan: ChunkPlan, _ index: Int) -> UInt64 {
    min(UInt64(plan.chunkSizeBytes), plan.sizeBytes - UInt64(index) * UInt64(plan.chunkSizeBytes))
}

/// Upload progress shared by the task group; only the group's own loop mutates it.
private final class LoadedTally: @unchecked Sendable {
    private(set) var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func add(_ bytes: UInt64) -> UInt64 {
        value += bytes
        return value
    }
}
