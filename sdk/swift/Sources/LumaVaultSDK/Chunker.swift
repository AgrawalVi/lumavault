import CryptoKit
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
    /// Default chunk slice size (`64 MiB`) for Cinema 4K media uploads.
    public static let cinemaChunkSizeBytes = maxChunkSizeBytes
    /// Buffer size (`32 KiB`) used when streaming files from disk.
    public static let streamBufferSizeBytes = 32 * 1024

    private static let sha256HexLength = 64
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

    /// Streams a file from disk in `32 KiB` `autoreleasepool` blocks and returns its lowercase hex `SHA-256`.
    public static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let reachedEOF: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: streamBufferSizeBytes), !chunk.isEmpty else {
                    return true
                }
                hasher.update(data: chunk)
                return false
            }
            if reachedEOF {
                break
            }
        }
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

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let expectedTotalBytes = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        var fileHasher = SHA256()
        var chunkHasher = SHA256()
        var chunks: [ChunkDescriptor] = []
        if expectedTotalBytes > 0 {
            let estimatedChunks = Int((expectedTotalBytes + UInt64(chunkSizeBytes) - 1) / UInt64(chunkSizeBytes))
            chunks.reserveCapacity(estimatedChunks)
        }

        var totalBytesRead: UInt64 = 0
        var currentChunkOffset: UInt64 = 0
        var currentChunkLength = 0

        while true {
            try Task.checkCancellation()
            let readLimit = min(streamBufferSizeBytes, chunkSizeBytes - currentChunkLength)
            let bytesReadCount: Int = try autoreleasepool {
                guard let buffer = try handle.read(upToCount: readLimit), !buffer.isEmpty else {
                    return 0
                }
                fileHasher.update(data: buffer)
                chunkHasher.update(data: buffer)
                return buffer.count
            }

            if bytesReadCount == 0 {
                break
            }

            totalBytesRead += UInt64(bytesReadCount)
            currentChunkLength += bytesReadCount

            if currentChunkLength == chunkSizeBytes {
                chunks.append(
                    ChunkDescriptor(
                        index: chunks.count,
                        hash: hexString(chunkHasher.finalize()),
                        offset: currentChunkOffset,
                        length: currentChunkLength
                    )
                )
                chunkHasher = SHA256()
                currentChunkOffset += UInt64(currentChunkLength)
                currentChunkLength = 0
            }

            onProgress?(totalBytesRead, max(totalBytesRead, expectedTotalBytes))
        }

        if currentChunkLength > 0 {
            chunks.append(
                ChunkDescriptor(
                    index: chunks.count,
                    hash: hexString(chunkHasher.finalize()),
                    offset: currentChunkOffset,
                    length: currentChunkLength
                )
            )
        } else if totalBytesRead == 0 {
            onProgress?(0, 0)
        }

        return ChunkPlan(
            sizeBytes: totalBytesRead,
            chunkSizeBytes: chunkSizeBytes,
            sha256Digest: hexString(fileHasher.finalize()),
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

        let estimatedChunks = (totalCount + chunkSizeBytes - 1) / chunkSizeBytes
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

    /// Seeks to `offset` in `fileURL` and reads an exact `length`-byte chunk slice on demand.
    public static func readChunk(
        from fileURL: URL,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        guard length >= 0 && length <= maxChunkSizeBytes else {
            throw LumaVaultError.invalidChunkSize(length)
        }
        try Task.checkCancellation()

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: offset)
        if length == 0 {
            return Data()
        }

        var result = Data()
        result.reserveCapacity(length)

        while result.count < length {
            try Task.checkCancellation()
            let remaining = length - result.count
            guard let part = try handle.read(upToCount: remaining), !part.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(part)
        }
        return result
    }

    /// Reads a planned `ChunkDescriptor` slice from `fileURL` on demand.
    public static func readChunk(from fileURL: URL, chunk: ChunkDescriptor) throws -> Data {
        try readChunk(from: fileURL, offset: chunk.offset, length: chunk.length)
    }

    /// Extracts a `ChunkDescriptor` slice from an in-memory `Data` value, respecting non-zero `startIndex`.
    public static func sliceData(_ data: Data, chunk: ChunkDescriptor) throws -> Data {
        guard chunk.length >= 0 && chunk.length <= maxChunkSizeBytes else {
            throw LumaVaultError.invalidChunkSize(chunk.length)
        }
        guard chunk.offset <= UInt64(data.count),
              Int(chunk.offset) + chunk.length <= data.count
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let start = data.index(data.startIndex, offsetBy: Int(chunk.offset))
        let end = data.index(start, offsetBy: chunk.length)
        return Data(data[start..<end])
    }

    internal static func hexString(_ digest: SHA256Digest) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(sha256HexLength)
        for byte in digest {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
