import Connect
import CryptoKit
import Foundation
import Testing

@testable import LumaVaultSDK

@Suite(.serialized) struct DataPlaneTests {
    let base = URL(string: "http://gw:8080")!
    let hash = String(repeating: "a", count: 64)

    private func dataPlane() -> DataPlane {
        DataPlane(baseURL: base, session: URLSession(configuration: StubURLProtocol.session()))
    }

    @Test(arguments: [(400, Code.invalidArgument), (401, .unauthenticated), (403, .permissionDenied), (404, .notFound), (413, .invalidArgument), (500, .internalError), (503, .unavailable)])
    func mapsStatusToConnectCode(status: Int, expected: Code) async {
        StubURLProtocol.handler = { _ in (status, Data(#"{"error":"boom"}"#.utf8)) }
        let error = await #expect(throws: ConnectError.self) { try await dataPlane().getChunk(sha256: hash, ticket: nil) }
        #expect(error?.code == expected)
        #expect(error?.message == "boom")
    }

    @Test func buildsRoutesWithOrWithoutTrailingSlash() {
        for base in ["http://gw:8080", "http://gw:8080/"].map({ URL(string: $0)! }) {
            #expect(gatewayChunkURL(baseURL: base, sha256: "ab12").absoluteString == "http://gw:8080/v1/chunks/ab12")
            #expect(gatewayStreamURL(baseURL: base, objectID: "obj/1").absoluteString == "http://gw:8080/v1/stream/obj%2F1")
        }
    }

    @Test func stagesTheRequestedRangeOfAFile() throws {
        let source = FileManager.default.temporaryDirectory.appending(component: "stage-\(UUID().uuidString)")
        try ChunkVectors.patternBytes(count: 3 * 1024 * 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try stageRange(of: source, offset: 1000, length: 2 * 1024 * 1024 + 5)
        defer { try? FileManager.default.removeItem(at: staged) }

        let expected = ChunkVectors.patternBytes(count: 3 * 1024 * 1024).subdata(in: 1000..<(1000 + 2 * 1024 * 1024 + 5))
        #expect(try Data(contentsOf: staged) == expected)
    }

    @Test func downloadFailsWithDataLossOnCorruptChunk() async throws {
        let good = Data("hello".utf8)
        var object = ObjectMetadata()
        object.id = "obj1"
        object.chunkHashes = [SHA256.hash(data: good).lowercaseHex]
        object.sha256Digest = SHA256.hash(data: good).lowercaseHex
        StubURLProtocol.handler = { _ in (200, Data("jello".utf8)) }

        let destination = FileManager.default.temporaryDirectory.appending(component: "dl-\(UUID().uuidString)")
        let error = await #expect(throws: ConnectError.self) {
            try await downloadVerified(object: object, dataPlane: dataPlane(), to: destination, ticket: nil)
        }
        #expect(error?.code == .dataLoss)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
