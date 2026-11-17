import CryptoKit
import Foundation

/// Downloads an object's chunks into a file, checking each chunk and then the whole file.
/// Bytes land in a temporary file first, so a failed download never leaves a partial file
/// at the destination. Only one chunk is in memory at a time.
func downloadVerified(object: ObjectMetadata, dataPlane: DataPlane, to destination: URL) async throws {
    let staging = destination.deletingLastPathComponent()
        .appending(component: ".\(destination.lastPathComponent).lumavault-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: staging.path, contents: nil)
    var moved = false
    defer {
        if !moved { try? FileManager.default.removeItem(at: staging) }
    }

    let writer = try FileHandle(forWritingTo: staging)
    var whole = SHA256()
    do {
        for (index, expected) in object.chunkHashes.enumerated() {
            try Task.checkCancellation()
            let bytes = try await dataPlane.getChunk(sha256: expected)
            guard SHA256.hash(data: bytes).lowercaseHex == expected else {
                throw hashMismatch("chunk \(index) of object \(object.id)")
            }
            whole.update(data: bytes)
            try writer.write(contentsOf: bytes)
        }
        try writer.close()
    } catch {
        try? writer.close()
        throw error
    }

    guard whole.finalize().lowercaseHex == object.sha256Digest else {
        throw hashMismatch("object \(object.id)")
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
    } else {
        try FileManager.default.moveItem(at: staging, to: destination)
    }
    moved = true
}
