import Foundation
import Testing

/// The cross-SDK vectors shared with the web tests, in sdk/testdata/chunk-vectors.json.
struct ChunkVectors: Decodable {
    struct SizeRule: Decodable {
        let sizeBytes: UInt64
        let chunkSizeBytes: Int
    }

    struct FileVector: Decodable, CustomTestStringConvertible {
        let name: String
        let sizeBytes: Int
        let chunkSizeBytes: Int
        let sha256: String
        let chunkHashes: [String]

        var testDescription: String { name }
    }

    let chunkSizeRule: [SizeRule]
    let files: [FileVector]

    static let shared: ChunkVectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../testdata/chunk-vectors.json")
            .standardizedFileURL
        // Force unwraps are fine here: a broken fixture should fail the whole test run loudly.
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(ChunkVectors.self, from: data)
    }()

    /// Bytes of the vector pattern, where byte i is i mod 251.
    static func patternBytes(count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }
}
