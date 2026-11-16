import Connect
import Foundation
import SwiftProtobuf

/// Progress phases emitted during `LumaVaultClient.uploadFile` and `LumaVaultClient.uploadData`.
public enum UploadProgress: Sendable, Equatable {
    case hashing(bytesHashed: UInt64, totalBytes: UInt64)
    case checking(totalChunks: Int)
    case uploading(completedChunks: Int, totalChunks: Int)
    case committing
}

/// Outcome of committing an uploaded object manifest via `LumaVaultClient`.
public struct UploadResult: Sendable, Equatable {
    public let object: Lumavault_V1_ObjectMetadata
    public let deduplicated: Bool

    public init(object: Lumavault_V1_ObjectMetadata, deduplicated: Bool) {
        self.object = object
        self.deduplicated = deduplicated
    }
}

/// Top-level `Sendable` client combining Connect-RPC (`StorageService`) control plane calls
/// and `URLSession` (`DataPlaneClient`) streaming chunk transfers.
public final class LumaVaultClient: Sendable {
    /// Default upper bound on concurrent `PUT /v1/chunks/{sha256}` transfers per upload.
    public static let defaultMaxConcurrentUploads = 2

    public let baseURL: URL
    public let dataPlane: DataPlaneClient
    private let storageClient: any Lumavault_V1_StorageServiceClientInterface

    public init(
        baseURL: URL,
        storageClient: any Lumavault_V1_StorageServiceClientInterface,
        dataPlane: DataPlaneClient
    ) {
        self.baseURL = baseURL
        self.storageClient = storageClient
        self.dataPlane = dataPlane
    }

    public convenience init(
        baseURL: URL,
        configuration: URLSessionConfiguration = .default
    ) {
        let httpClient = URLSessionHTTPClient(configuration: configuration)
        let config = ProtocolClientConfig(
            host: Self.normalizedHost(from: baseURL),
            networkProtocol: .connect,
            codec: ProtoCodec()
        )
        let protocolClient = ProtocolClient(httpClient: httpClient, config: config)
        let storageClient = Lumavault_V1_StorageServiceClient(client: protocolClient)
        let dataPlane = DataPlaneClient(baseURL: baseURL, configuration: configuration)
        self.init(
            baseURL: baseURL,
            storageClient: storageClient,
            dataPlane: dataPlane
        )
    }

    // MARK: - Deduplicated Upload Pipeline

    /// Streams `fileURL` in `32 KiB` buffers, checks missing chunks via `HasChunks`, uploads only
    /// unique missing chunks with bounded concurrency, and commits the full ordered manifest.
    public func uploadFile(
        at fileURL: URL,
        namespace: Lumavault_V1_Namespace,
        filename: String? = nil,
        mimeType: String = "application/octet-stream",
        thumbnail: Data? = nil,
        chunkSizeBytes: Int? = nil,
        skipDedup: Bool = false,
        maxConcurrentUploads: Int = defaultMaxConcurrentUploads,
        headers: Connect.Headers = [:],
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> UploadResult {
        try await executeUpload(
            namespace: namespace,
            filename: filename ?? fileURL.lastPathComponent,
            mimeType: mimeType,
            thumbnail: thumbnail,
            chunkSizeBytes: chunkSizeBytes,
            skipDedup: skipDedup,
            maxConcurrentUploads: maxConcurrentUploads,
            headers: headers,
            onProgress: onProgress,
            makePlan: { chunkSize, onHashProgress in
                try Chunker.planFile(
                    at: fileURL,
                    chunkSizeBytes: chunkSize,
                    onProgress: onHashProgress
                )
            },
            loadChunk: { descriptor in
                try Chunker.readChunk(from: fileURL, chunk: descriptor)
            }
        )
    }

    /// Slices an in-memory `Data` payload, checks missing chunks via `HasChunks`, uploads only
    /// unique missing chunks with bounded concurrency, and commits the full ordered manifest.
    public func uploadData(
        _ data: Data,
        namespace: Lumavault_V1_Namespace,
        filename: String,
        mimeType: String = "application/octet-stream",
        thumbnail: Data? = nil,
        chunkSizeBytes: Int? = nil,
        skipDedup: Bool = false,
        maxConcurrentUploads: Int = defaultMaxConcurrentUploads,
        headers: Connect.Headers = [:],
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> UploadResult {
        try await executeUpload(
            namespace: namespace,
            filename: filename,
            mimeType: mimeType,
            thumbnail: thumbnail,
            chunkSizeBytes: chunkSizeBytes,
            skipDedup: skipDedup,
            maxConcurrentUploads: maxConcurrentUploads,
            headers: headers,
            onProgress: onProgress,
            makePlan: { chunkSize, onHashProgress in
                try Chunker.planData(
                    data,
                    chunkSizeBytes: chunkSize,
                    onProgress: onHashProgress
                )
            },
            loadChunk: { descriptor in
                try Chunker.sliceData(data, chunk: descriptor)
            }
        )
    }

    // MARK: - Control Plane RPC Wrappers

    /// Checks which candidate `SHA-256` chunk hashes are missing in `ChunkStore`.
    public func hasChunks(
        _ chunkHashes: [String],
        headers: Connect.Headers = [:]
    ) async throws -> [String] {
        try Task.checkCancellation()
        for hash in chunkHashes {
            try Chunker.validateHash(hash)
        }
        var request = Lumavault_V1_HasChunksRequest()
        request.chunkHashes = chunkHashes
        let response = await storageClient.hasChunks(request: request, headers: headers)
        return try unwrap(response).missingChunkHashes
    }

    /// Commits an object manifest after all referenced chunks have been uploaded.
    public func commitObject(
        _ request: Lumavault_V1_CommitObjectRequest,
        headers: Connect.Headers = [:]
    ) async throws -> Lumavault_V1_CommitObjectResponse {
        try Task.checkCancellation()
        let response = await storageClient.commitObject(request: request, headers: headers)
        let message = try unwrap(response)
        guard message.hasObject else {
            throw LumaVaultError.invalidResponse("CommitObject response missing object")
        }
        return message
    }

    /// Fetches a single object's metadata and chunk manifest by ID.
    public func getObject(
        objectID: String,
        headers: Connect.Headers = [:]
    ) async throws -> Lumavault_V1_ObjectMetadata {
        try Task.checkCancellation()
        var request = Lumavault_V1_GetObjectRequest()
        request.objectID = objectID
        let response = await storageClient.getObject(request: request, headers: headers)
        let message = try unwrap(response)
        guard message.hasObject else {
            throw LumaVaultError.invalidResponse("GetObject response missing object")
        }
        return message.object
    }

    /// Lists a single page of objects within `namespace`.
    public func listObjects(
        namespace: Lumavault_V1_Namespace,
        pageSize: Int32 = 0,
        pageToken: String = "",
        headers: Connect.Headers = [:]
    ) async throws -> Lumavault_V1_ListObjectsResponse {
        try Task.checkCancellation()
        _ = try Chunker.defaultChunkSize(for: namespace)
        var request = Lumavault_V1_ListObjectsRequest()
        request.namespace = namespace
        request.pageSize = pageSize
        request.pageToken = pageToken
        let response = await storageClient.listObjects(request: request, headers: headers)
        return try unwrap(response)
    }

    /// Streams all objects in `namespace` across cursor pages, canceling the producer task on termination.
    public func listAllObjects(
        namespace: Lumavault_V1_Namespace,
        pageSize: Int32 = 0,
        headers: Connect.Headers = [:]
    ) -> AsyncThrowingStream<Lumavault_V1_ObjectMetadata, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var pageToken = ""
                    var seenTokens = Set<String>()
                    while true {
                        try Task.checkCancellation()
                        let page = try await self.listObjects(
                            namespace: namespace,
                            pageSize: pageSize,
                            pageToken: pageToken,
                            headers: headers
                        )
                        for object in page.objects {
                            try Task.checkCancellation()
                            if case .terminated = continuation.yield(object) {
                                return
                            }
                        }
                        if page.nextPageToken.isEmpty {
                            continuation.finish()
                            return
                        }
                        guard seenTokens.insert(page.nextPageToken).inserted else {
                            throw LumaVaultError.invalidResponse(
                                "ListObjects returned repeating next_page_token"
                            )
                        }
                        pageToken = page.nextPageToken
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Partially updates mutable storage-level metadata fields using an automatically constructed `FieldMask`.
    public func updateObjectMetadata(
        objectID: String,
        filename: String? = nil,
        mimeType: String? = nil,
        thumbnailChunkHash: String? = nil,
        headers: Connect.Headers = [:]
    ) async throws -> Lumavault_V1_ObjectMetadata {
        try Task.checkCancellation()
        var object = Lumavault_V1_ObjectMetadata()
        object.id = objectID

        var paths: [String] = []
        if let filename {
            object.filename = filename
            paths.append("filename")
        }
        if let mimeType {
            object.mimeType = mimeType
            paths.append("mime_type")
        }
        if let thumbnailChunkHash {
            if !thumbnailChunkHash.isEmpty {
                try Chunker.validateHash(thumbnailChunkHash)
            }
            object.thumbnailChunkHash = thumbnailChunkHash
            paths.append("thumbnail_chunk_hash")
        }
        guard !paths.isEmpty else {
            throw LumaVaultError.emptyUpdateMask
        }

        var mask = Google_Protobuf_FieldMask()
        mask.paths = paths

        var request = Lumavault_V1_UpdateObjectMetadataRequest()
        request.object = object
        request.updateMask = mask

        let response = await storageClient.updateObjectMetadata(request: request, headers: headers)
        let message = try unwrap(response)
        guard message.hasObject else {
            throw LumaVaultError.invalidResponse("UpdateObjectMetadata response missing object")
        }
        return message.object
    }

    /// Deletes an object's metadata record by ID.
    public func deleteObject(
        objectID: String,
        headers: Connect.Headers = [:]
    ) async throws {
        try Task.checkCancellation()
        var request = Lumavault_V1_DeleteObjectRequest()
        request.objectID = objectID
        let response = await storageClient.deleteObject(request: request, headers: headers)
        _ = try unwrap(response)
    }

    // MARK: - Verified Downloads & URL Helpers

    /// Downloads `object` to `destinationURL`, verifying `SHA-256` against `object.sha256Digest`
    /// without issuing an extra `GetObject` RPC.
    public func downloadObjectToFile(
        _ object: Lumavault_V1_ObjectMetadata,
        to destinationURL: URL
    ) async throws {
        try await dataPlane.downloadStreamToFile(
            objectID: object.id,
            to: destinationURL,
            expectedSHA256: object.sha256Digest
        )
    }

    /// Downloads `objectID` to `destinationURL`, verifying `SHA-256` against `expectedSHA256`
    /// or the Gateway's strong `ETag` header without an extra `GetObject` RPC.
    public func downloadObjectToFile(
        objectID: String,
        to destinationURL: URL,
        expectedSHA256: String? = nil
    ) async throws {
        try await dataPlane.downloadStreamToFile(
            objectID: objectID,
            to: destinationURL,
            expectedSHA256: expectedSHA256
        )
    }

    /// Downloads `object` into memory, enforcing `maxBytes` and verifying `object.sha256Digest`
    /// without issuing an extra `GetObject` RPC.
    public func downloadObjectData(
        _ object: Lumavault_V1_ObjectMetadata,
        maxBytes: Int64 = DataPlaneClient.defaultMaxDownloadBytes
    ) async throws -> Data {
        if maxBytes >= 0, object.sizeBytes > UInt64(maxBytes) {
            throw LumaVaultError.payloadTooLarge(
                sizeBytes: Int64(clamping: object.sizeBytes),
                maxBytes: maxBytes
            )
        }
        return try await dataPlane.downloadStreamData(
            objectID: object.id,
            expectedSHA256: object.sha256Digest,
            maxBytes: maxBytes
        )
    }

    /// Downloads `objectID` into memory, enforcing `maxBytes` and verifying `expectedSHA256`
    /// or the Gateway's strong `ETag` header without an extra `GetObject` RPC.
    public func downloadObjectData(
        objectID: String,
        expectedSHA256: String? = nil,
        maxBytes: Int64 = DataPlaneClient.defaultMaxDownloadBytes
    ) async throws -> Data {
        try await dataPlane.downloadStreamData(
            objectID: objectID,
            expectedSHA256: expectedSHA256,
            maxBytes: maxBytes
        )
    }

    /// Builds `${baseURL}/v1/stream/${objectID}` for `AVPlayer` `HTTP 206` byte-range streaming.
    public func streamURL(forObjectID objectID: String) -> URL {
        dataPlane.streamURL(forObjectID: objectID)
    }

    /// Builds `${baseURL}/v1/chunks/${hash}` for immutable content-addressed chunks.
    public func chunkURL(forHash hash: String) -> URL {
        dataPlane.chunkURL(forHash: hash)
    }

    /// Returns `${baseURL}/v1/chunks/${object.thumbnailChunkHash}`, or `nil` when `thumbnailChunkHash` is empty.
    public func thumbnailURL(for object: Lumavault_V1_ObjectMetadata) -> URL? {
        guard !object.thumbnailChunkHash.isEmpty else {
            return nil
        }
        return dataPlane.chunkURL(forHash: object.thumbnailChunkHash)
    }

    // MARK: - Private Helpers

    private struct UploadUnit: Sendable {
        let hash: String
        let loadBytes: @Sendable () throws -> Data
    }

    private func executeUpload(
        namespace: Lumavault_V1_Namespace,
        filename: String,
        mimeType: String,
        thumbnail: Data?,
        chunkSizeBytes: Int?,
        skipDedup: Bool,
        maxConcurrentUploads: Int,
        headers: Connect.Headers,
        onProgress: (@Sendable (UploadProgress) -> Void)?,
        makePlan: (_ chunkSize: Int, _ onHashProgress: @escaping (UInt64, UInt64) -> Void) throws -> ChunkPlan,
        loadChunk: @escaping @Sendable (ChunkDescriptor) throws -> Data
    ) async throws -> UploadResult {
        try Task.checkCancellation()
        let defaultSize = try Chunker.defaultChunkSize(for: namespace)
        let resolvedChunkSize = chunkSizeBytes ?? defaultSize
        try Chunker.validateChunkSize(resolvedChunkSize)

        let thumbnailPayload: (hash: String, data: Data)?
        if let thumbnail, !thumbnail.isEmpty {
            if thumbnail.count > Chunker.maxChunkSizeBytes {
                throw LumaVaultError.payloadTooLarge(
                    sizeBytes: Int64(thumbnail.count),
                    maxBytes: Int64(Chunker.maxChunkSizeBytes)
                )
            }
            thumbnailPayload = (Chunker.sha256Hex(of: thumbnail), thumbnail)
        } else {
            thumbnailPayload = nil
        }

        let plan = try makePlan(resolvedChunkSize) { bytesHashed, totalBytes in
            onProgress?(.hashing(bytesHashed: bytesHashed, totalBytes: totalBytes))
        }

        let orderedChunkHashes = plan.chunks.map(\.hash)
        var uniqueUnits: [UploadUnit] = []
        uniqueUnits.reserveCapacity(plan.chunks.count + (thumbnailPayload == nil ? 0 : 1))
        var seenHashes = Set<String>()
        seenHashes.reserveCapacity(plan.chunks.count + 1)

        for descriptor in plan.chunks {
            if seenHashes.insert(descriptor.hash).inserted {
                uniqueUnits.append(
                    UploadUnit(hash: descriptor.hash) {
                        try loadChunk(descriptor)
                    }
                )
            }
        }
        if let thumbnailPayload, seenHashes.insert(thumbnailPayload.hash).inserted {
            let thumbBytes = thumbnailPayload.data
            uniqueUnits.append(
                UploadUnit(hash: thumbnailPayload.hash) {
                    thumbBytes
                }
            )
        }

        if !uniqueUnits.isEmpty {
            try Task.checkCancellation()
            onProgress?(.checking(totalChunks: uniqueUnits.count))

            let missingHashes = try await hasChunks(uniqueUnits.map(\.hash), headers: headers)
            let missingSet = Set(missingHashes)
            let missingUnits = uniqueUnits.filter { missingSet.contains($0.hash) }

            if !missingUnits.isEmpty {
                let concurrency = max(1, min(maxConcurrentUploads, missingUnits.count))
                onProgress?(.uploading(completedChunks: 0, totalChunks: missingUnits.count))

                try await withThrowingTaskGroup(of: Void.self) { [dataPlane] group in
                    var nextIndex = 0
                    while nextIndex < concurrency {
                        let unit = missingUnits[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            try Task.checkCancellation()
                            let bytes = try unit.loadBytes()
                            try await dataPlane.putChunk(data: bytes, hash: unit.hash)
                        }
                    }

                    var completed = 0
                    while try await group.next() != nil {
                        completed += 1
                        onProgress?(.uploading(completedChunks: completed, totalChunks: missingUnits.count))

                        if nextIndex < missingUnits.count {
                            try Task.checkCancellation()
                            let unit = missingUnits[nextIndex]
                            nextIndex += 1
                            group.addTask {
                                try Task.checkCancellation()
                                let bytes = try unit.loadBytes()
                                try await dataPlane.putChunk(data: bytes, hash: unit.hash)
                            }
                        }
                    }
                }
            }
        }

        try Task.checkCancellation()
        onProgress?(.committing)

        var commitReq = Lumavault_V1_CommitObjectRequest()
        commitReq.namespace = namespace
        commitReq.filename = filename
        commitReq.mimeType = mimeType
        commitReq.sizeBytes = plan.sizeBytes
        commitReq.chunkSizeBytes = UInt32(plan.chunkSizeBytes)
        commitReq.sha256Digest = plan.sha256Digest
        commitReq.chunkHashes = orderedChunkHashes
        if let thumbnailPayload {
            commitReq.thumbnailChunkHash = thumbnailPayload.hash
        }
        commitReq.skipDedup = skipDedup

        let commitResp = try await commitObject(commitReq, headers: headers)
        return UploadResult(object: commitResp.object, deduplicated: commitResp.deduplicated)
    }

    private func unwrap<Output: ProtobufMessage>(
        _ response: ResponseMessage<Output>
    ) throws -> Output {
        switch response.result {
        case .success(let message):
            return message
        case .failure(let error):
            if error.code == .canceled && Task.isCancelled {
                throw CancellationError()
            }
            throw LumaVaultError.rpcError(
                code: error.code,
                message: error.message ?? error.errorDescription
            )
        }
    }

    private static func normalizedHost(from baseURL: URL) -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return baseURL.absoluteString
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.url?.absoluteString ?? baseURL.absoluteString
    }
}
