/// Picks the chunk size for a file: start at 4 MiB and double until the file fits in at most
/// 256 chunks, capped at 64 MiB. Deterministic so the same file always yields the same chunks.
func chunkSize(forFileSize sizeBytes: UInt64) -> Int {
    var size = ChunkingConstants.minChunkSizeBytes
    while size < ChunkingConstants.maxChunkSizeBytes
        && UInt64(size) * UInt64(ChunkingConstants.targetMaxChunks) < sizeBytes
    {
        size *= 2
    }
    return size
}
