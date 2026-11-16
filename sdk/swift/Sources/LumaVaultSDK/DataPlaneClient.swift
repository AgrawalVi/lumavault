import CryptoKit
import Foundation

/// Raw HTTP Data Plane client (`PUT/GET /v1/chunks/{sha256}` and `GET /v1/stream/{object_id}`)
/// backed by `URLSession`.
public struct DataPlaneClient: Sendable {
    /// Default `256 MiB` safety ceiling for in-memory `downloadStreamData` transfers.
    public static let defaultMaxDownloadBytes: Int64 = 256 * 1024 * 1024

    private static let singleSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public init(baseURL: URL, configuration: URLSessionConfiguration = .default) {
        self.init(baseURL: baseURL, session: URLSession(configuration: configuration))
    }

    /// Builds `${baseURL}/v1/stream/${objectID}` for `AVPlayer` `HTTP 206` byte-range streaming.
    public func streamURL(forObjectID objectID: String) -> URL {
        endpointURL(subpath: "/v1/stream", segment: objectID)
    }

    /// Builds `${baseURL}/v1/chunks/${hash}` for immutable content-addressed chunks and thumbnails.
    public func chunkURL(forHash hash: String) -> URL {
        endpointURL(subpath: "/v1/chunks", segment: hash)
    }

    /// Uploads a single chunk via `PUT /v1/chunks/{sha256}` (`application/octet-stream`),
    /// validating `{sha256}` and the `64 MiB` chunk ceiling locally before sending.
    public func putChunk(data: Data, hash: String) async throws {
        try Task.checkCancellation()
        try Chunker.validateHash(hash)
        if data.count > Chunker.maxChunkSizeBytes {
            throw LumaVaultError.payloadTooLarge(
                sizeBytes: Int64(data.count),
                maxBytes: Int64(Chunker.maxChunkSizeBytes)
            )
        }

        var request = URLRequest(url: chunkURL(forHash: hash))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

        let (responseData, response) = try await session.upload(for: request, from: data)
        let httpResponse = try requireHTTPResponse(response)
        if httpResponse.statusCode == 413 {
            throw LumaVaultError.payloadTooLarge(
                sizeBytes: Int64(data.count),
                maxBytes: Int64(Chunker.maxChunkSizeBytes)
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LumaVaultError.httpError(
                statusCode: httpResponse.statusCode,
                message: Self.decodeErrorMessage(from: responseData)
            )
        }
    }

    /// Downloads a single chunk via `GET /v1/chunks/{sha256}` and verifies its `SHA-256` digest by default.
    public func getChunk(hash: String, verifyHash: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        try Chunker.validateHash(hash)

        var request = URLRequest(url: chunkURL(forHash: hash))
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        let httpResponse = try requireHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LumaVaultError.httpError(
                statusCode: httpResponse.statusCode,
                message: Self.decodeErrorMessage(from: data)
            )
        }
        if data.count > Chunker.maxChunkSizeBytes {
            throw LumaVaultError.payloadTooLarge(
                sizeBytes: Int64(data.count),
                maxBytes: Int64(Chunker.maxChunkSizeBytes)
            )
        }
        if verifyHash {
            let actualHash = Chunker.sha256Hex(of: data)
            guard actualHash == hash else {
                throw LumaVaultError.hashMismatch(expected: hash, actual: actualHash)
            }
        }
        return data
    }

    /// Streams `GET /v1/stream/{object_id}` to disk via `URLSession.download`, verifies `SHA-256`
    /// in `32 KiB` `autoreleasepool` blocks (against `expectedSHA256` or a quote-stripped strong `ETag`),
    /// and atomically replaces `destinationURL`. Always cleans up temporary files on error or cancellation.
    public func downloadStreamToFile(
        objectID: String,
        to destinationURL: URL,
        expectedSHA256: String? = nil
    ) async throws {
        try Task.checkCancellation()
        if let expectedSHA256 {
            try Chunker.validateHash(expectedSHA256)
        }

        var request = URLRequest(url: streamURL(forObjectID: objectID))
        request.httpMethod = "GET"

        let (tempURL, response) = try await session.download(for: request)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let httpResponse = try requireHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorSnippet = Self.readErrorSnippet(at: tempURL)
            throw LumaVaultError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorSnippet
            )
        }

        let expectedHash = try Self.resolveExpectedSHA256(
            explicit: expectedSHA256,
            response: httpResponse
        )
        let actualHash = try Chunker.sha256Hex(ofFileAt: tempURL)
        guard actualHash == expectedHash else {
            throw LumaVaultError.hashMismatch(expected: expectedHash, actual: actualHash)
        }

        let destinationDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        _ = try FileManager.default.replaceItemAt(
            destinationURL,
            withItemAt: tempURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }

    /// Streams `GET /v1/stream/{object_id}` into memory (`URLSession.bytes`), enforcing `maxBytes`
    /// incrementally and verifying `SHA-256` against `expectedSHA256` or a quote-stripped strong `ETag`.
    public func downloadStreamData(
        objectID: String,
        expectedSHA256: String? = nil,
        maxBytes: Int64 = defaultMaxDownloadBytes
    ) async throws -> Data {
        try Task.checkCancellation()
        if let expectedSHA256 {
            try Chunker.validateHash(expectedSHA256)
        }
        guard maxBytes >= 0 else {
            throw LumaVaultError.payloadTooLarge(sizeBytes: 0, maxBytes: maxBytes)
        }

        var request = URLRequest(url: streamURL(forObjectID: objectID))
        request.httpMethod = "GET"

        let (asyncBytes, response) = try await session.bytes(for: request)
        let httpResponse = try requireHTTPResponse(response)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try await Self.readErrorMessage(from: asyncBytes)
            throw LumaVaultError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let expectedHash = try Self.resolveExpectedSHA256(
            explicit: expectedSHA256,
            response: httpResponse
        )
        if httpResponse.expectedContentLength > maxBytes {
            throw LumaVaultError.payloadTooLarge(
                sizeBytes: httpResponse.expectedContentLength,
                maxBytes: maxBytes
            )
        }

        var result = Data()
        if httpResponse.expectedContentLength > 0, httpResponse.expectedContentLength <= maxBytes {
            result.reserveCapacity(Int(httpResponse.expectedContentLength))
        }

        var hasher = SHA256()
        var scratch = [UInt8]()
        scratch.reserveCapacity(Chunker.streamBufferSizeBytes)
        var totalBytes: Int64 = 0

        for try await byte in asyncBytes {
            totalBytes += 1
            if totalBytes > maxBytes {
                throw LumaVaultError.payloadTooLarge(sizeBytes: totalBytes, maxBytes: maxBytes)
            }
            scratch.append(byte)
            if scratch.count == Chunker.streamBufferSizeBytes {
                try Task.checkCancellation()
                hasher.update(data: scratch)
                result.append(contentsOf: scratch)
                scratch.removeAll(keepingCapacity: true)
            }
        }
        if !scratch.isEmpty {
            hasher.update(data: scratch)
            result.append(contentsOf: scratch)
        }

        let actualHash = Chunker.hexString(hasher.finalize())
        guard actualHash == expectedHash else {
            throw LumaVaultError.hashMismatch(expected: expectedHash, actual: actualHash)
        }
        return result
    }

    // MARK: - Private Helpers

    private func endpointURL(subpath: String, segment: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return baseURL
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let encodedSegment = segment.addingPercentEncoding(withAllowedCharacters: Self.singleSegmentAllowed) ?? segment
        components.percentEncodedPath = "\(basePath)\(subpath)/\(encodedSegment)"
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.url ?? baseURL
    }

    private func requireHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LumaVaultError.invalidResponse("Expected HTTPURLResponse")
        }
        return httpResponse
    }

    private static func resolveExpectedSHA256(
        explicit: String?,
        response: HTTPURLResponse
    ) throws -> String {
        if let explicit {
            return explicit
        }
        guard let rawETag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawETag.isEmpty
        else {
            throw LumaVaultError.invalidResponse("Missing ETag header for SHA-256 verification")
        }
        if rawETag.hasPrefix("W/") || rawETag.hasPrefix("w/") {
            throw LumaVaultError.invalidResponse("Weak ETag header cannot verify SHA-256: \(rawETag)")
        }
        let unquoted: String
        if rawETag.hasPrefix("\"") || rawETag.hasSuffix("\"") {
            guard rawETag.count >= 2, rawETag.hasPrefix("\""), rawETag.hasSuffix("\"") else {
                throw LumaVaultError.invalidResponse("Malformed ETag header: \(rawETag)")
            }
            unquoted = String(rawETag.dropFirst().dropLast())
        } else {
            unquoted = rawETag
        }
        do {
            try Chunker.validateHash(unquoted)
        } catch {
            throw LumaVaultError.invalidResponse("ETag header is not a valid SHA-256 digest: \(rawETag)")
        }
        return unquoted
    }

    private static func decodeErrorMessage(from data: Data) -> String {
        String(data: data.prefix(4096), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readErrorSnippet(at fileURL: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ""
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else {
            return ""
        }
        return decodeErrorMessage(from: data)
    }

    private static func readErrorMessage(from asyncBytes: URLSession.AsyncBytes) async throws -> String {
        var bytes = [UInt8]()
        for try await byte in asyncBytes {
            bytes.append(byte)
            if bytes.count >= 4096 {
                break
            }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
