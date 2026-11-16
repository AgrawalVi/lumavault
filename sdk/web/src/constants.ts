/** Minimum chunk size (4 MiB) and default for Photos and Games namespaces. */
export const MIN_CHUNK_SIZE_BYTES = 4 * 1024 * 1024;

/** Maximum chunk size (64 MiB) and default for Cinema namespace. */
export const MAX_CHUNK_SIZE_BYTES = 64 * 1024 * 1024;

/** Default chunk size (4 MiB) when no namespace or explicit chunk size is provided. */
export const DEFAULT_CHUNK_SIZE_BYTES = MIN_CHUNK_SIZE_BYTES;

/** Default chunk size (64 MiB) for high-bitrate Cinema media. */
export const CINEMA_CHUNK_SIZE_BYTES = MAX_CHUNK_SIZE_BYTES;

/** Default maximum in-memory download size (256 MiB) enforced by downloadStream. */
export const DEFAULT_MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024;

/** Exact character length of a hex-encoded SHA-256 digest. */
export const SHA256_HEX_LENGTH = 64;

/** Canonical lowercase hex SHA-256 digest of a 0-byte payload. */
export const EMPTY_SHA256_DIGEST =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
