// Chunk sizing bounds. These must match the web SDK and sdk/testdata/chunk-vectors.json,
// or identical files uploaded from different clients stop sharing chunks.
enum ChunkingConstants {
    static let minChunkSizeBytes = 4 * 1024 * 1024
    static let maxChunkSizeBytes = 64 * 1024 * 1024
    static let targetMaxChunks = 256

    // Files are read in pieces this size so memory stays flat no matter how big a chunk is.
    static let readBufferBytes = 1024 * 1024
}

// Chunk uploads in flight at once, matching the web SDK default.
let defaultUploadConcurrency = 4

// Gateway data plane routes, relative to the gateway base URL.
enum GatewayRoutes {
    static let chunks = "v1/chunks"
    static let stream = "v1/stream"
}
