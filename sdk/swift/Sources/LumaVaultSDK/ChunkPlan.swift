import Connect
import CryptoKit
import Foundation

/// The manifest fields CommitObject needs, computed locally before any network call.
struct ChunkPlan: Equatable, Sendable {
    let sizeBytes: UInt64
    let chunkSizeBytes: Int
    /// Lowercase hex SHA-256 of the whole file.
    let sha256Digest: String
    /// Lowercase hex SHA-256 of each chunk, in order.
    let chunkHashes: [String]
}

/// Splits the file into chunks and hashes each chunk and the whole file in one pass.
/// The file is read in small pieces, so memory stays flat even for multi-gigabyte files.
func planChunks(fileURL: URL) throws -> ChunkPlan {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    let sizeBytes = try handle.seekToEnd()
    guard sizeBytes > 0 else {
        throw ConnectError(code: .invalidArgument, message: "empty files cannot be uploaded")
    }
    try handle.seek(toOffset: 0)

    let chunkSizeBytes = chunkSize(forFileSize: sizeBytes)
    var whole = SHA256()
    var chunk = SHA256()
    var chunkHashes: [String] = []
    var bytesInChunk = 0

    while true {
        let wanted = min(ChunkingConstants.readBufferBytes, chunkSizeBytes - bytesInChunk)
        guard let piece = try handle.read(upToCount: wanted), !piece.isEmpty else { break }
        whole.update(data: piece)
        chunk.update(data: piece)
        bytesInChunk += piece.count
        if bytesInChunk == chunkSizeBytes {
            chunkHashes.append(chunk.finalize().lowercaseHex)
            chunk = SHA256()
            bytesInChunk = 0
        }
    }
    if bytesInChunk > 0 {
        chunkHashes.append(chunk.finalize().lowercaseHex)
    }

    return ChunkPlan(
        sizeBytes: sizeBytes,
        chunkSizeBytes: chunkSizeBytes,
        sha256Digest: whole.finalize().lowercaseHex,
        chunkHashes: chunkHashes
    )
}
