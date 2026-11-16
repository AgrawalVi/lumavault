// Chunk sizing bounds. These must match the web SDK and sdk/testdata/chunk-vectors.json,
// or identical files uploaded from different clients stop sharing chunks.
enum ChunkingConstants {
    static let minChunkSizeBytes = 4 * 1024 * 1024
    static let maxChunkSizeBytes = 64 * 1024 * 1024
    static let targetMaxChunks = 256

    // Files are read in pieces this size so memory stays flat no matter how big a chunk is.
    static let readBufferBytes = 1024 * 1024
}
