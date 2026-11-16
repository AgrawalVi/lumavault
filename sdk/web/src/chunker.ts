import {
  CINEMA_CHUNK_SIZE_BYTES,
  DEFAULT_CHUNK_SIZE_BYTES,
  EMPTY_SHA256_DIGEST,
  MAX_CHUNK_SIZE_BYTES,
  MIN_CHUNK_SIZE_BYTES,
} from "./constants.js";
import { Namespace } from "./gen/lumavault/v1/storage_pb.js";
import { Sha256, sha256Hex } from "./sha256.js";
import type {
  ChunkPlan,
  PlannedChunk,
  PrepareChunkPlanOptions,
} from "./types.js";

export {
  CINEMA_CHUNK_SIZE_BYTES,
  DEFAULT_CHUNK_SIZE_BYTES,
  EMPTY_SHA256_DIGEST,
  MAX_CHUNK_SIZE_BYTES,
  MIN_CHUNK_SIZE_BYTES,
  SHA256_HEX_LENGTH,
} from "./constants.js";
export {
  Sha256,
  assertValidSha256Hex,
  isValidSha256Hex,
  sha256Hex,
} from "./sha256.js";
export type {
  ChunkHashProgress,
  ChunkPlan,
  PlannedChunk,
  PrepareChunkPlanOptions,
} from "./types.js";

/** Returns the default chunk size in bytes for the given LumaVault storage namespace. */
export function defaultChunkSizeForNamespace(namespace: Namespace): number {
  switch (namespace) {
    case Namespace.CINEMA:
      return CINEMA_CHUNK_SIZE_BYTES;
    case Namespace.PHOTOS:
    case Namespace.GAMES:
      return DEFAULT_CHUNK_SIZE_BYTES;
    default:
      throw new RangeError(`Unsupported or unspecified namespace: ${String(namespace)}`);
  }
}

/** Returns true if chunkSizeBytes is an integer from 4 MiB through 64 MiB. */
export function isValidChunkSize(chunkSizeBytes: number): boolean {
  return (
    Number.isSafeInteger(chunkSizeBytes) &&
    chunkSizeBytes >= MIN_CHUNK_SIZE_BYTES &&
    chunkSizeBytes <= MAX_CHUNK_SIZE_BYTES
  );
}

/** Throws a RangeError if chunkSizeBytes is outside 4 MiB through 64 MiB. */
export function assertValidChunkSize(chunkSizeBytes: number): void {
  if (!isValidChunkSize(chunkSizeBytes)) {
    throw new RangeError(
      `chunkSizeBytes must be an integer between ${MIN_CHUNK_SIZE_BYTES} (4 MiB) and ${MAX_CHUNK_SIZE_BYTES} (64 MiB), got ${String(chunkSizeBytes)}`,
    );
  }
}

// Isolated outside prepareChunkPlan so retained PlannedChunk.slice closures never pin per-chunk
// chunkBytes buffers inside debugger or inspector block contexts on 50 GB+ files.
function createChunkSlice(
  input: Blob | Uint8Array,
  offset: number,
  end: number,
): () => Blob | Uint8Array {
  return input instanceof Uint8Array
    ? () => input.subarray(offset, end)
    : () => input.slice(offset, end);
}

/**
 * Slices a Blob, File, or Uint8Array into fixed-size chunks and computes per-chunk plus
 * whole-file SHA-256 digests in a single pass while holding at most one chunk in memory.
 */
export async function prepareChunkPlan(
  input: Blob | Uint8Array,
  options: PrepareChunkPlanOptions = {},
): Promise<ChunkPlan> {
  const { signal, onProgress } = options;
  signal?.throwIfAborted();

  if (!(input instanceof Uint8Array) && !(input instanceof Blob)) {
    throw new TypeError("input must be a Blob, File, or Uint8Array");
  }

  const namespaceDefault =
    options.namespace !== undefined
      ? defaultChunkSizeForNamespace(options.namespace)
      : DEFAULT_CHUNK_SIZE_BYTES;
  const chunkSizeBytes = options.chunkSizeBytes ?? namespaceDefault;
  if (options.chunkSizeBytes !== undefined) {
    assertValidChunkSize(chunkSizeBytes);
  }

  const isBytes = input instanceof Uint8Array;
  const sizeBytes = isBytes ? input.byteLength : input.size;
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 0) {
    throw new RangeError(`Invalid input byte length: ${String(sizeBytes)}`);
  }

  if (sizeBytes === 0) {
    onProgress?.({ hashedBytes: 0, totalBytes: 0, chunkIndex: 0, totalChunks: 0 });
    return {
      sizeBytes: 0,
      chunkSizeBytes,
      sha256Digest: EMPTY_SHA256_DIGEST,
      chunks: [],
    };
  }

  const totalChunks = Math.ceil(sizeBytes / chunkSizeBytes);
  const chunks: PlannedChunk[] = [];
  const wholeFileHasher = totalChunks > 1 ? new Sha256() : null;

  for (let index = 0; index < totalChunks; index++) {
    signal?.throwIfAborted();
    const offset = index * chunkSizeBytes;
    const len = Math.min(chunkSizeBytes, sizeBytes - offset);
    const end = offset + len;

    const chunkBytes = isBytes
      ? input.subarray(offset, end)
      : new Uint8Array(await input.slice(offset, end).arrayBuffer());
    signal?.throwIfAborted();

    const digestPromise = sha256Hex(chunkBytes, signal);
    wholeFileHasher?.update(chunkBytes);
    const chunkHash = await digestPromise;
    signal?.throwIfAborted();

    chunks.push({
      index,
      hash: chunkHash,
      offset,
      sizeBytes: len,
      slice: createChunkSlice(input, offset, end),
    });

    onProgress?.({
      hashedBytes: end,
      totalBytes: sizeBytes,
      chunkIndex: index + 1,
      totalChunks,
    });
  }

  const sha256Digest = wholeFileHasher ? wholeFileHasher.digestHex() : chunks[0]!.hash;

  return {
    sizeBytes,
    chunkSizeBytes,
    sha256Digest,
    chunks,
  };
}
