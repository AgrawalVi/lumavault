import Connect
import Foundation
import Testing

@testable import LumaVaultSDK

@Suite struct ChunkPlanTests {
    @Test(arguments: ChunkVectors.shared.chunkSizeRule.map { ($0.sizeBytes, $0.chunkSizeBytes) })
    func chunkSizeMatchesSharedRule(sizeBytes: UInt64, expected: Int) {
        #expect(chunkSize(forFileSize: sizeBytes) == expected)
    }

    @Test(arguments: ChunkVectors.shared.files)
    func planMatchesSharedVector(_ vector: ChunkVectors.FileVector) throws {
        let url = try writeTempFile(ChunkVectors.patternBytes(count: vector.sizeBytes))
        defer { try? FileManager.default.removeItem(at: url) }

        let plan = try planChunks(fileURL: url)

        #expect(plan.sizeBytes == UInt64(vector.sizeBytes))
        #expect(plan.chunkSizeBytes == vector.chunkSizeBytes)
        #expect(plan.sha256Digest == vector.sha256)
        #expect(plan.chunkHashes == vector.chunkHashes)
    }

    @Test func emptyFileIsRejected() throws {
        let url = try writeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let error = #expect(throws: ConnectError.self) { try planChunks(fileURL: url) }
        #expect(error?.code == .invalidArgument)
    }

    private func writeTempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumavault-chunk-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}
