import type { Namespace } from "./gen/lumavault/v1/storage_pb.js";

export interface ChunkHashProgress {
  hashedBytes: number;
  totalBytes: number;
  chunkIndex: number;
  totalChunks: number;
}

export interface PrepareChunkPlanOptions {
  chunkSizeBytes?: number;
  namespace?: Namespace;
  signal?: AbortSignal;
  onProgress?: (progress: ChunkHashProgress) => void;
}

export interface PlannedChunk {
  readonly index: number;
  readonly hash: string;
  readonly offset: number;
  readonly sizeBytes: number;
  /** Returns a lazy zero-copy slice (Blob.slice or Uint8Array.subarray) for this chunk. */
  slice(): Blob | Uint8Array;
}

export interface ChunkPlan {
  readonly sizeBytes: number;
  readonly chunkSizeBytes: number;
  readonly sha256Digest: string;
  readonly chunks: PlannedChunk[];
}

export type DataPlaneErrorCode =
  | "INVALID_HASH"
  | "HASH_MISMATCH"
  | "PAYLOAD_TOO_LARGE"
  | "NOT_FOUND"
  | "HTTP_ERROR";

export interface LumaVaultDataPlaneErrorOptions {
  status?: number;
  cause?: unknown;
}

export interface DataPlaneRequestOptions {
  fetch?: typeof globalThis.fetch;
  signal?: AbortSignal;
}

export interface PutChunkOptions extends DataPlaneRequestOptions {
  /** Re-hashes data locally before uploading to verify it matches sha256 (default: false). */
  verifyLocalHash?: boolean;
}

export interface PutChunkResult {
  readonly sha256: string;
  readonly sizeBytes: number;
}

export interface GetChunkOptions extends DataPlaneRequestOptions {
  /** Verifies that downloaded bytes hash to sha256 (default: true). */
  verify?: boolean;
}

export interface DownloadStreamOptions extends DataPlaneRequestOptions {
  /** Expected whole-object SHA-256 digest; falls back to quote-stripped strong ETag if omitted. */
  expectedSha256?: string;
  /** Maximum bytes buffered in memory before aborting as too large (default: 256 MiB). */
  maxBytes?: number;
}
