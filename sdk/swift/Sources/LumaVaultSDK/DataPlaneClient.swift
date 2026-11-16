import CryptoKit
import Darwin
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

    private final class SessionOwner: Sendable {
        let session: URLSession
        init(_ session: URLSession) {
            self.session = session
        }
        deinit {
            session.finishTasksAndInvalidate()
        }
    }

    public let baseURL: URL
    private let session: URLSession
    private let sessionOwner: SessionOwner?

    public init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
        self.sessionOwner = nil
    }

    public init(baseURL: URL, configuration: URLSessionConfiguration = .default) {
        let owned = URLSession(configuration: configuration)
        self.baseURL = baseURL
        self.session = owned
        self.sessionOwner = SessionOwner(owned)
    }

    /// Validates that `objectID` is non-empty, not a dot path segment (`.` / `..`),
    /// and contains no ASCII control characters.
    public static func validateObjectID(_ objectID: String) throws {
        guard !objectID.isEmpty,
              objectID != ".",
              objectID != "..",
              !objectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !objectID.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F })
        else {
            throw LumaVaultError.invalidArgument("Invalid object ID: \(objectID)")
        }
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

    /// Downloads a single chunk via `GET /v1/chunks/{sha256}`, streaming with a `64 MiB` cap
    /// and verifying its `SHA-256` digest by default.
    public func getChunk(hash: String, verifyHash: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        try Chunker.validateHash(hash)

        return try await streamBoundedBytes(
            url: chunkURL(forHash: hash),
            maxBytes: Int64(Chunker.maxChunkSizeBytes),
            expectedSHA256: verifyHash ? hash : nil,
            requireVerification: verifyHash
        )
    }

    /// Streams `GET /v1/stream/{object_id}` to disk via `URLSession.download`, verifies `SHA-256`
    /// in `32 KiB` `autoreleasepool` blocks (against `expectedSHA256` or a quote-stripped strong `ETag`),
    /// and atomically replaces `destinationURL` (including across volumes). Always cleans up temporary files.
    public func downloadStreamToFile(
        objectID: String,
        to destinationURL: URL,
        expectedSHA256: String? = nil
    ) async throws {
        try Task.checkCancellation()
        try Self.validateObjectID(objectID)
        guard destinationURL.isFileURL, !destinationURL.hasDirectoryPath else {
            throw LumaVaultError.invalidArgument("Destination must be a file URL: \(destinationURL)")
        }
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
        guard httpResponse.statusCode == 200 else {
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

        let fileManager = FileManager.default
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let replacementDir = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: destinationDir,
            create: true
        )
        defer {
            try? fileManager.removeItem(at: replacementDir)
        }

        let stagedURL = replacementDir.appendingPathComponent(destinationURL.lastPathComponent)
        try fileManager.moveItem(at: tempURL, to: stagedURL)
        _ = stagedURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(0) }
            return Darwin.chmod(path, mode_t(0o644))
        }

        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: stagedURL,
            backupItemName: nil,
            options: []
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
        try Self.validateObjectID(objectID)
        if let expectedSHA256 {
            try Chunker.validateHash(expectedSHA256)
        }

        return try await streamBoundedBytes(
            url: streamURL(forObjectID: objectID),
            maxBytes: maxBytes,
            expectedSHA256: expectedSHA256,
            requireVerification: true
        )
    }

    // MARK: - Private Helpers

    private func streamBoundedBytes(
        url: URL,
        maxBytes: Int64,
        expectedSHA256: String?,
        requireVerification: Bool
    ) async throws -> Data {
        guard maxBytes >= 0 else {
            throw LumaVaultError.payloadTooLarge(sizeBytes: 0, maxBytes: maxBytes)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (asyncBytes, response) = try await session.bytes(for: request)
        defer {
            asyncBytes.task.cancel()
        }
        try Task.checkCancellation()

        let httpResponse = try requireHTTPResponse(response)
        guard httpResponse.statusCode == 200 else {
            let message = try await Self.readErrorMessage(from: asyncBytes)
            throw LumaVaultError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let expectedHash: String? = requireVerification
            ? try Self.resolveExpectedSHA256(explicit: expectedSHA256, response: httpResponse)
            : nil

        if httpResponse.expectedContentLength > maxBytes {
            throw LumaVaultError.payloadTooLarge(
                sizeBytes: httpResponse.expectedContentLength,
                maxBytes: maxBytes
            )
        }

        var result = Data()
        if httpResponse.expectedContentLength > 0 {
            let cappedReserve = min(httpResponse.expectedContentLength, Int64(Chunker.minChunkSizeBytes))
            result.reserveCapacity(Int(cappedReserve))
        }

        var hasher = expectedHash != nil ? SHA256() : nil
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
                hasher?.update(data: scratch)
                result.append(contentsOf: scratch)
                scratch.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !scratch.isEmpty {
            hasher?.update(data: scratch)
            result.append(contentsOf: scratch)
        }

        if let expectedHash, let hasher {
            let actualHash = Chunker.hexString(hasher.finalize())
            guard actualHash == expectedHash else {
                throw LumaVaultError.hashMismatch(expected: expectedHash, actual: actualHash)
            }
        }
        return result
    }

    private func endpointURL(subpath: String, segment: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return baseURL
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let encodedSegment: String
        if segment == "." {
            encodedSegment = "%2E"
        } else if segment == ".." {
            encodedSegment = "%2E%2E"
        } else {
            guard let escaped = segment.addingPercentEncoding(withAllowedCharacters: Self.singleSegmentAllowed) else {
                return baseURL
            }
            encodedSegment = escaped
        }
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
        guard rawETag.count >= 2, rawETag.first == "\"", rawETag.last == "\"" else {
            throw LumaVaultError.invalidResponse("Malformed strong ETag header: \(rawETag)")
        }
        let unquoted = String(rawETag.dropFirst().dropLast())
        do {
            try Chunker.validateHash(unquoted)
        } catch {
            throw LumaVaultError.invalidResponse("ETag header is not a valid SHA-256 digest: \(rawETag)")
        }
        return unquoted
    }

    private static func decodeErrorMessage(from data: Data) -> String {
        String(decoding: data.prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        try Task.checkCancellation()
        return decodeErrorMessage(from: Data(bytes))
    }
}
