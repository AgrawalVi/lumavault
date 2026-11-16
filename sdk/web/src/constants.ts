// Chunk sizing bounds. These must match the Swift SDK and sdk/testdata/chunk-vectors.json,
// or identical files uploaded from different clients stop sharing chunks.
export const MIN_CHUNK_SIZE_BYTES = 4 * 1024 * 1024;
export const MAX_CHUNK_SIZE_BYTES = 64 * 1024 * 1024;
export const TARGET_MAX_CHUNKS = 256;
