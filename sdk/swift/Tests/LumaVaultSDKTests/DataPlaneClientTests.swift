import Foundation
import XCTest
@testable import LumaVaultSDK

final class DataPlaneClientTests: XCTestCase {
    private var tempDirectory: URL!
    private var session: URLSession!
    private var client: DataPlaneClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumavault-dataplane-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = DataPlaneClient(
            baseURL: URL(string: "https://vault.example.com/")!,
            session: session
        )
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        MockURLProtocol.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testURLBuildersNormalizeSlashesAndEncodeObjectIDs() {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(
            client.chunkURL(forHash: hash).absoluteString,
            "https://vault.example.com/v1/chunks/\(hash)"
        )
        XCTAssertEqual(
            client.streamURL(forObjectID: "obj-123").absoluteString,
            "https://vault.example.com/v1/stream/obj-123"
        )

        let prefixed = DataPlaneClient(
            baseURL: URL(string: "http://localhost:8080/api///")!,
            session: session
        )
        XCTAssertEqual(
            prefixed.streamURL(forObjectID: "folder/save 1?v=2#frag").absoluteString,
            "http://localhost:8080/api/v1/stream/folder%2Fsave%201%3Fv=2%23frag"
        )
    }

    func testPutChunkValidatesLocallyAndUploadsOctetStream() async throws {
        let payload = Data("lumavault-chunk-payload".utf8)
        let hash = Chunker.sha256Hex(of: payload)

        // Invalid hash fails locally without hitting URLSession.
        do {
            try await client.putChunk(data: payload, hash: "bad-hash")
            XCTFail("Expected invalidHash error")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .invalidHash("bad-hash"))
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        // Oversized chunk (> 64 MiB) fails locally without hitting URLSession.
        let oversized = Data(count: Chunker.maxChunkSizeBytes + 1)
        do {
            try await client.putChunk(data: oversized, hash: String(repeating: "0", count: 64))
            XCTFail("Expected payloadTooLarge error")
        } catch let error as LumaVaultError {
            XCTAssertEqual(
                error,
                .payloadTooLarge(
                    sizeBytes: Int64(Chunker.maxChunkSizeBytes + 1),
                    maxBytes: Int64(Chunker.maxChunkSizeBytes)
                )
            )
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        // Valid upload hits PUT /v1/chunks/{sha256} with application/octet-stream.
        MockURLProtocol.setHandler { request, body in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/chunks/\(hash)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(body, payload)
            return MockResponse(
                statusCode: 201,
                headers: ["Content-Type": "application/json"],
                body: Data("{\"sha256\":\"\(hash)\",\"size_bytes\":\(payload.count)}".utf8)
            )
        }

        try await client.putChunk(data: payload, hash: hash)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // Server 413 maps to payloadTooLarge.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 413, body: Data("too large".utf8))
        }
        do {
            try await client.putChunk(data: payload, hash: hash)
            XCTFail("Expected payloadTooLarge")
        } catch let error as LumaVaultError {
            XCTAssertEqual(
                error,
                .payloadTooLarge(
                    sizeBytes: Int64(payload.count),
                    maxBytes: Int64(Chunker.maxChunkSizeBytes)
                )
            )
        }
    }

    func testGetChunkVerifiesSHA256AndDetectsCorruption() async throws {
        let payload = Data("immutable-thumbnail-bytes".utf8)
        let hash = Chunker.sha256Hex(of: payload)

        MockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/chunks/\(hash)")
            return MockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream", "ETag": "\"\(hash)\""],
                body: payload
            )
        }

        let downloaded = try await client.getChunk(hash: hash)
        XCTAssertEqual(downloaded, payload)

        // Flip one byte in transit -> must throw hashMismatch.
        var corrupted = payload
        corrupted[0] ^= 0xFF
        let corruptedHash = Chunker.sha256Hex(of: corrupted)

        MockURLProtocol.setHandler { [corrupted] _, _ in
            MockResponse(statusCode: 200, body: corrupted)
        }

        do {
            _ = try await client.getChunk(hash: hash)
            XCTFail("Expected hashMismatch")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .hashMismatch(expected: hash, actual: corruptedHash))
        }
    }

    func testDownloadStreamToFileQuotedETagAndAtomicOverwrite() async throws {
        // Use > 32 KiB (96 KiB) so multi-block 32 KiB autoreleasepool hashing is exercised.
        let initialBytes = Data((0 ..< 96 * 1024).map { UInt8($0 & 0xFF) })
        let initialHash = Chunker.sha256Hex(of: initialBytes)
        let destination = tempDirectory.appendingPathComponent("nested/rom.gba")

        MockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/stream/obj-rom-1")
            return MockResponse(
                statusCode: 200,
                headers: ["ETag": "\"\(initialHash)\""],
                body: initialBytes
            )
        }

        try await client.downloadStreamToFile(objectID: "obj-rom-1", to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), initialBytes)

        // Overwrite existing file atomically with updated content.
        let updatedBytes = Data("updated-save-state-v2".utf8)
        let updatedHash = Chunker.sha256Hex(of: updatedBytes)

        MockURLProtocol.setHandler { _, _ in
            MockResponse(
                statusCode: 200,
                headers: ["ETag": "\"\(updatedHash)\""],
                body: updatedBytes
            )
        }

        try await client.downloadStreamToFile(objectID: "obj-rom-1", to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), updatedBytes)
    }

    func testDownloadStreamToFileRejectsMissingOrWeakETagAndCleansUpTempFiles() async throws {
        let originalContent = Data("keep-me-safe".utf8)
        let destination = tempDirectory.appendingPathComponent("safe.sav")
        try originalContent.write(to: destination)

        let payload = Data("unverified-stream".utf8)
        let payloadHash = Chunker.sha256Hex(of: payload)

        // 1. Missing ETag when expectedSHA256 is nil -> invalidResponse.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 200, headers: [:], body: payload)
        }
        let beforeMissing = snapshotCFNetworkTempFiles()
        do {
            try await client.downloadStreamToFile(objectID: "obj-no-etag", to: destination)
            XCTFail("Expected invalidResponse for missing ETag")
        } catch let error as LumaVaultError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(snapshotCFNetworkTempFiles().subtracting(beforeMissing).isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), originalContent)

        // 2. Weak ETag -> invalidResponse.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 200, headers: ["ETag": "W/\"\(payloadHash)\""], body: payload)
        }
        do {
            try await client.downloadStreamToFile(objectID: "obj-weak-etag", to: destination)
            XCTFail("Expected invalidResponse for weak ETag")
        } catch let error as LumaVaultError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), originalContent)

        // 3. HTTP 404 -> httpError and cleans up temp file, leaving existing destination intact.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 404, body: Data("object not found".utf8))
        }
        let before404 = snapshotCFNetworkTempFiles()
        do {
            try await client.downloadStreamToFile(objectID: "obj-missing", to: destination)
            XCTFail("Expected 404 httpError")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .httpError(statusCode: 404, message: "object not found"))
        }
        XCTAssertTrue(snapshotCFNetworkTempFiles().subtracting(before404).isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), originalContent)

        // 4. Corrupted body -> hashMismatch, cleans up temp file, leaves existing destination intact.
        let wrongExpected = String(repeating: "f", count: 64)
        MockURLProtocol.setHandler { _, _ in
            MockResponse(
                statusCode: 200,
                headers: ["ETag": "\"\(wrongExpected)\""],
                body: payload
            )
        }
        let beforeMismatch = snapshotCFNetworkTempFiles()
        do {
            try await client.downloadStreamToFile(objectID: "obj-corrupt", to: destination)
            XCTFail("Expected hashMismatch")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .hashMismatch(expected: wrongExpected, actual: payloadHash))
        }
        XCTAssertTrue(snapshotCFNetworkTempFiles().subtracting(beforeMismatch).isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), originalContent)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path),
            ["safe.sav"]
        )
    }

    func testDownloadStreamDataVerifiesETagAndEnforcesMaxBytesCap() async throws {
        let saveBytes = Data((0 ..< 80 * 1024).map { UInt8(($0 * 3) & 0xFF) })
        let saveHash = Chunker.sha256Hex(of: saveBytes)

        MockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/stream/save-v1")
            return MockResponse(
                statusCode: 200,
                headers: ["ETag": "\"\(saveHash)\""],
                body: saveBytes
            )
        }

        let downloaded = try await client.downloadStreamData(objectID: "save-v1")
        XCTAssertEqual(downloaded, saveBytes)

        // Exceeding maxBytes aborts with payloadTooLarge.
        do {
            _ = try await client.downloadStreamData(objectID: "save-v1", maxBytes: 1024)
            XCTFail("Expected payloadTooLarge")
        } catch let error as LumaVaultError {
            guard case .payloadTooLarge(_, let maxBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maxBytes, 1024)
        }

        // Explicit expectedSHA256 succeeds even without ETag.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 200, headers: [:], body: saveBytes)
        }
        let verifiedExplicit = try await client.downloadStreamData(
            objectID: "save-v1",
            expectedSHA256: saveHash
        )
        XCTAssertEqual(verifiedExplicit, saveBytes)

        // Declared Content-Length exceeding maxBytes fast-fails with payloadTooLarge.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(
                statusCode: 200,
                headers: ["ETag": "\"\(saveHash)\"", "Content-Length": "8192"],
                body: saveBytes
            )
        }
        do {
            _ = try await client.downloadStreamData(objectID: "save-v1", maxBytes: 1024)
            XCTFail("Expected payloadTooLarge from Content-Length")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .payloadTooLarge(sizeBytes: 8192, maxBytes: 1024))
        }

        // Missing ETag without expectedSHA256 throws invalidResponse.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 200, headers: [:], body: saveBytes)
        }
        do {
            _ = try await client.downloadStreamData(objectID: "save-v1")
            XCTFail("Expected invalidResponse")
        } catch let error as LumaVaultError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func snapshotCFNetworkTempFiles() -> Set<String> {
        let tempPath = FileManager.default.temporaryDirectory.path
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tempPath)) ?? []
        return Set(entries.filter { $0.hasPrefix("CFNetworkDownload_") })
    }
}

// MARK: - MockURLProtocol

private struct MockResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> MockResponse

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
        var count = 0
    }

    private static let state = State()

    static var requestCount: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.count
    }

    static func setHandler(_ newHandler: @escaping Handler) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.handler = newHandler
    }

    static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.handler = nil
        state.count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let activeHandler: Handler? = {
            Self.state.lock.lock()
            defer { Self.state.lock.unlock() }
            Self.state.count += 1
            return Self.state.handler
        }()

        guard let activeHandler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let body = Self.readRequestBody(from: request)
            let mock = try activeHandler(request, body)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: mock.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: mock.headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !mock.body.isEmpty {
                client?.urlProtocol(self, didLoad: mock.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readRequestBody(from request: URLRequest) -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
