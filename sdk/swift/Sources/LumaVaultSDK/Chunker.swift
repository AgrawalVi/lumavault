import CryptoKit
import Darwin
import Foundation

/// Metadata describing a single content-addressed slice within a planned file or `Data` buffer.
public struct ChunkDescriptor: Sendable, Equatable {
    public let index: Int
    public let hash: String
    public let offset: UInt64
    public let length: Int

    public init(index: Int, hash: String, offset: UInt64, length: Int) {
        self.index = index
        self.hash = hash
        self.offset = offset
        self.length = length
    }
}

/// Complete manifest plan produced by slicing and hashing a file or `Data` payload.
public struct ChunkPlan: Sendable, Equatable {
    public let sizeBytes: UInt64
    public let chunkSizeBytes: Int
    public let sha256Digest: String
    public let chunks: [ChunkDescriptor]

    public init(
        sizeBytes: UInt64,
        chunkSizeBytes: Int,
        sha256Digest: String,
        chunks: [ChunkDescriptor]
    ) {
        self.sizeBytes = sizeBytes
        self.chunkSizeBytes = chunkSizeBytes
        self.sha256Digest = sha256Digest
        self.chunks = chunks
    }
}

/// Streaming file slicer and `CryptoKit` `SHA-256` hasher.
public enum Chunker {
    /// Minimum chunk slice size (`4 MiB`), also used as the default for Photos and Games.
    public static let minChunkSizeBytes = 4 * 1024 * 1024
    /// Maximum chunk slice size (`64 MiB`), also used as the default for Cinema.
    public static let maxChunkSizeBytes = 64 * 1024 * 1024
    /// Default chunk slice size (`4 MiB`) for general uploads.
    public static let defaultChunkSizeBytes = minChunkSizeBytes
    /// Buffer size (`32 KiB`) used when streaming files from disk.
    public static let streamBufferSizeBytes = 32 * 1024

    private static let sha256HexLength = 64
    private static let progressStepBytes: UInt64 = 1024 * 1024
    private static let maxReservedChunkCount: UInt64 = 16_384
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    /// Returns the default chunk size (`4 MiB` for Photos/Games, `64 MiB` for Cinema).
    public static func defaultChunkSize(for namespace: Lumavault_V1_Namespace) throws -> Int {
        switch namespace {
        case .photos, .games:
            return minChunkSizeBytes
        case .cinema:
            return maxChunkSizeBytes
        case .unspecified, .UNRECOGNIZED:
            throw LumaVaultError.invalidNamespace(namespace)
        }
    }

    /// Validates that `chunkSizeBytes` falls within `4 MiB...64 MiB`.
    public static func validateChunkSize(_ chunkSizeBytes: Int) throws {
        guard chunkSizeBytes >= minChunkSizeBytes && chunkSizeBytes <= maxChunkSizeBytes else {
            throw LumaVaultError.invalidChunkSize(chunkSizeBytes)
        }
    }

    /// Validates that `hash` is a canonical 64-character lowercase hexadecimal `SHA-256` digest.
    public static func validateHash(_ hash: String) throws {
        let utf8 = hash.utf8
        guard utf8.count == sha256HexLength else {
            throw LumaVaultError.invalidHash(hash)
        }
        for byte in utf8 {
            let isDigit = byte >= 0x30 && byte <= 0x39
            let isLowerHex = byte >= 0x61 && byte <= 0x66
            if !isDigit && !isLowerHex {
                throw LumaVaultError.invalidHash(hash)
            }
        }
    }

    /// Computes the lowercase hex `SHA-256` digest of an in-memory `Data` value.
    public static func sha256Hex(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// Streams a regular file from disk in `32 KiB` `autoreleasepool` blocks and returns its lowercase hex `SHA-256`.
    public static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        try Task.checkCancellation()
        let (handle, statBefore) = try openRegularFile(at: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytesRead: UInt64 = 0

        while true {
            try Task.checkCancellation()
            let bytesRead: Int = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: streamBufferSizeBytes), !chunk.isEmpty else {
                    return 0
                }
                hasher.update(data: chunk)
                return chunk.count
            }
            if bytesRead == 0 {
                break
            }
            totalBytesRead += UInt64(bytesRead)
        }

        try verifyUnmodified(handle, before: statBefore, bytesRead: totalBytesRead, fileURL: fileURL)
        return hexString(hasher.finalize())
    }

    /// Streams `fileURL` in `32 KiB` `autoreleasepool` blocks, computing per-chunk and whole-file
    /// `SHA-256` digests in a single pass with constant heap memory.
    public static func planFile(
        at fileURL: URL,
        chunkSizeBytes: Int = defaultChunkSizeBytes,
        onProgress: ((_ bytesHashed: UInt64, _ totalBytes: UInt64) -> Void)? = nil
    ) throws -> ChunkPlan {
        try validateChunkSize(chunkSizeBytes)
        try Task.checkCancellation()

        let (handle, statBefore) = try openRegularFile(at: fileURL)
        defer { try? handle.close() }

        let expectedTotalBytes = UInt64(statBefore.st_size)

        var fileHasher = SHA256()
        var chunkHasher = SHA256()
        var chunks: [ChunkDescriptor] = []
        if expectedTotalBytes > 0 {
            let estimatedChunks = 1 + (expectedTotalBytes - 1) / UInt64(chunkSizeBytes)
            chunks.reserveCapacity(Int(min(estimatedChunks, maxReservedChunkCount)))
        }

        var totalBytesRead: UInt64 = 0
        var lastReportedBytes: UInt64 = 0
        var currentChunkOffset: UInt64 = 0
        var currentChunkLength = 0

        while true {
            try Task.checkCancellation()
            let readLimit = min(streamBufferSizeBytes, chunkSizeBytes - currentChunkLength)
            let isFirstChunk = chunks.isEmpty
            let bytesReadCount: Int = try autoreleasepool {
                guard let buffer = try handle.read(upToCount: readLimit), !buffer.isEmpty else {
                    return 0
                }
                fileHasher.update(data: buffer)
                if !isFirstChunk {
                    chunkHasher.update(data: buffer)
                }
                return buffer.count
            }

            if bytesReadCount == 0 {
                break
            }

            totalBytesRead += UInt64(bytesReadCount)
            currentChunkLength += bytesReadCount

            var hitChunkBoundary = false
            if currentChunkLength == chunkSizeBytes {
                // SHA256.finalize() is nonmutating, so chunk 0 reuses fileHasher without hashing twice.
                let digest = isFirstChunk ? fileHasher.finalize() : chunkHasher.finalize()
                chunks.append(
                    ChunkDescriptor(
                        index: chunks.count,
                        hash: hexString(digest),
                        offset: currentChunkOffset,
                        length: currentChunkLength
                    )
                )
                chunkHasher = SHA256()
                currentChunkOffset += UInt64(currentChunkLength)
                currentChunkLength = 0
                hitChunkBoundary = true
            }

            if hitChunkBoundary || totalBytesRead - lastReportedBytes >= progressStepBytes {
                lastReportedBytes = totalBytesRead
                onProgress?(totalBytesRead, max(totalBytesRead, expectedTotalBytes))
            }
        }

        try verifyUnmodified(handle, before: statBefore, bytesRead: totalBytesRead, fileURL: fileURL)

        let wholeDigest = hexString(fileHasher.finalize())
        if currentChunkLength > 0 {
            let tailHash = chunks.isEmpty ? wholeDigest : hexString(chunkHasher.finalize())
            chunks.append(
                ChunkDescriptor(
                    index: chunks.count,
                    hash: tailHash,
                    offset: currentChunkOffset,
                    length: currentChunkLength
                )
            )
        }

        if totalBytesRead == 0 || lastReportedBytes < totalBytesRead {
            onProgress?(totalBytesRead, totalBytesRead)
        }

        return ChunkPlan(
            sizeBytes: totalBytesRead,
            chunkSizeBytes: chunkSizeBytes,
            sha256Digest: wholeDigest,
            chunks: chunks
        )
    }

    /// Plans chunks over an in-memory `Data` buffer, safely handling slices with non-zero `startIndex`.
    public static func planData(
        _ data: Data,
        chunkSizeBytes: Int = defaultChunkSizeBytes,
        onProgress: ((_ bytesHashed: UInt64, _ totalBytes: UInt64) -> Void)? = nil
    ) throws -> ChunkPlan {
        try validateChunkSize(chunkSizeBytes)
        try Task.checkCancellation()

        let totalCount = data.count
        if totalCount == 0 {
            onProgress?(0, 0)
            return ChunkPlan(
                sizeBytes: 0,
                chunkSizeBytes: chunkSizeBytes,
                sha256Digest: sha256Hex(of: Data()),
                chunks: []
            )
        }

        let estimatedChunks = 1 + (totalCount - 1) / chunkSizeBytes
        var chunks: [ChunkDescriptor] = []
        chunks.reserveCapacity(estimatedChunks)

        var fileHasher = SHA256()
        let isMultiChunk = totalCount > chunkSizeBytes
        var cursor = data.startIndex
        var logicalOffset: UInt64 = 0

        while cursor < data.endIndex {
            try Task.checkCancellation()
            let remaining = data.distance(from: cursor, to: data.endIndex)
            let sliceLength = min(chunkSizeBytes, remaining)
            let sliceEnd = data.index(cursor, offsetBy: sliceLength)
            let slice = data[cursor..<sliceEnd]

            let chunkDigestHex = hexString(SHA256.hash(data: slice))
            if isMultiChunk {
                fileHasher.update(data: slice)
            }

            chunks.append(
                ChunkDescriptor(
                    index: chunks.count,
                    hash: chunkDigestHex,
                    offset: logicalOffset,
                    length: sliceLength
                )
            )

            logicalOffset += UInt64(sliceLength)
            cursor = sliceEnd
            onProgress?(logicalOffset, UInt64(totalCount))
        }

        let wholeDigest = isMultiChunk ? hexString(fileHasher.finalize()) : chunks[0].hash
        return ChunkPlan(
            sizeBytes: UInt64(totalCount),
            chunkSizeBytes: chunkSizeBytes,
            sha256Digest: wholeDigest,
            chunks: chunks
        )
    }

    /// Seeks to `offset` in `fileURL` and streams an exact `length`-byte chunk slice in `32 KiB`
    /// `autoreleasepool` blocks.
    public static func readChunk(
        from fileURL: URL,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        try readChunkInternal(from: fileURL, offset: offset, length: length, expectedHash: nil)
    }

    /// Reads a planned `ChunkDescriptor` slice from `fileURL` on demand and verifies `chunk.hash`
    /// so concurrent on-disk mutations are caught before uploading.
    public static func readChunk(from fileURL: URL, chunk: ChunkDescriptor) throws -> Data {
        try validateHash(chunk.hash)
        return try readChunkInternal(
            from: fileURL,
            offset: chunk.offset,
            length: chunk.length,
            expectedHash: chunk.hash
        )
    }

    /// Extracts a `ChunkDescriptor` slice from an in-memory `Data` value, respecting non-zero `startIndex`.
    public static func sliceData(_ data: Data, chunk: ChunkDescriptor) throws -> Data {
        guard chunk.length >= 0 && chunk.length <= maxChunkSizeBytes else {
            throw LumaVaultError.invalidChunkSize(chunk.length)
        }
        guard chunk.offset <= UInt64(data.count),
              chunk.length <= data.count - Int(chunk.offset)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let start = data.index(data.startIndex, offsetBy: Int(chunk.offset))
        let end = data.index(start, offsetBy: chunk.length)
        return Data(data[start..<end])
    }

    // MARK: - Internal & Private Helpers

    internal static func hexString(_ digest: SHA256Digest) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(sha256HexLength)
        for byte in digest {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readChunkInternal(
        from fileURL: URL,
        offset: UInt64,
        length: Int,
        expectedHash: String?
    ) throws -> Data {
        guard length >= 0 && length <= maxChunkSizeBytes else {
            throw LumaVaultError.invalidChunkSize(length)
        }
        try Task.checkCancellation()

        let (handle, _) = try openRegularFile(at: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: offset)

        if length == 0 {
            if let expectedHash {
                let emptyHash = sha256Hex(of: Data())
                guard emptyHash == expectedHash else {
                    throw LumaVaultError.hashMismatch(expected: expectedHash, actual: emptyHash)
                }
            }
            return Data()
        }

        var result = Data(capacity: length)
        var hasher = expectedHash != nil ? SHA256() : nil

        while result.count < length {
            try Task.checkCancellation()
            let readLimit = min(streamBufferSizeBytes, length - result.count)
            let gotEOF: Bool = try autoreleasepool {
                guard let part = try handle.read(upToCount: readLimit), !part.isEmpty else {
                    return true
                }
                hasher?.update(data: part)
                result.append(part)
                return false
            }
            if gotEOF {
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        if let expectedHash, let hasher {
            let actualHash = hexString(hasher.finalize())
            guard actualHash == expectedHash else {
                throw LumaVaultError.hashMismatch(expected: expectedHash, actual: actualHash)
            }
        }
        return result
    }

    private static func openRegularFile(at fileURL: URL) throws -> (FileHandle, Darwin.stat) {
        guard fileURL.isFileURL,
              !fileURL.hasDirectoryPath,
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != false
        else {
            throw LumaVaultError.invalidArgument("URL is not a regular file: \(fileURL.path)")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        do {
            let st = try statRegularFile(handle, fileURL: fileURL)
            return (handle, st)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func statRegularFile(_ handle: FileHandle, fileURL: URL) throws -> Darwin.stat {
        var st = Darwin.stat()
        guard Darwin.fstat(handle.fileDescriptor, &st) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else {
            throw LumaVaultError.invalidArgument("URL is not a regular file: \(fileURL.path)")
        }
        return st
    }

    private static func verifyUnmodified(
        _ handle: FileHandle,
        before: Darwin.stat,
        bytesRead: UInt64,
        fileURL: URL
    ) throws {
        let after = try statRegularFile(handle, fileURL: fileURL)
        guard bytesRead == UInt64(before.st_size),
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
