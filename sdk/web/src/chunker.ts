import {
  CINEMA_CHUNK_SIZE_BYTES,
  DEFAULT_CHUNK_SIZE_BYTES,
  EMPTY_SHA256_DIGEST,
  MAX_CHUNK_SIZE_BYTES,
  MIN_CHUNK_SIZE_BYTES,
} from "./constants.js";
import { Namespace } from "./gen/lumavault/v1/storage_pb.js";
import { Sha256, bytesToHex, toBufferSource } from "./sha256.js";
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
  bytesToHex,
  isValidSha256Hex,
  sha256Hex,
  toBufferSource,
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

/** Returns true if `chunkSizeBytes` is an integer within `[4 MiB, 64 MiB]`. */
export function isValidChunkSize(chunkSizeBytes: number): boolean {
  return (
    Number.isSafeInteger(chunkSizeBytes) &&
    chunkSizeBytes >= MIN_CHUNK_SIZE_BYTES &&
    chunkSizeBytes <= MAX_CHUNK_SIZE_BYTES
  );
}

/** Throws a `RangeError` if `chunkSizeBytes` is outside `[4 MiB, 64 MiB]`. */
export function assertValidChunkSize(chunkSizeBytes: number): void {
  if (!isValidChunkSize(chunkSizeBytes)) {
    throw new RangeError(
      `chunkSizeBytes must be an integer between ${MIN_CHUNK_SIZE_BYTES} (4 MiB) and ${MAX_CHUNK_SIZE_BYTES} (64 MiB), got ${String(chunkSizeBytes)}`,
    );
  }
}

/**
 * Slices a `Blob`/`File` or `Uint8Array` into fixed-size chunks and computes per-chunk plus
 * whole-file `SHA-256` digests in a single pass while holding at most one chunk in memory.
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

  let chunkSizeBytes: number;
  if (options.chunkSizeBytes !== undefined) {
    if (options.namespace !== undefined) {
      defaultChunkSizeForNamespace(options.namespace);
    }
    assertValidChunkSize(options.chunkSizeBytes);
    chunkSizeBytes = options.chunkSizeBytes;
  } else if (options.namespace !== undefined) {
    chunkSizeBytes = defaultChunkSizeForNamespace(options.namespace);
  } else {
    chunkSizeBytes = DEFAULT_CHUNK_SIZE_BYTES;
  }

  const isBytes = input instanceof Uint8Array;
  const sizeBytes = isBytes ? input.byteLength : input.size;

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
      ? toBufferSource(input.subarray(offset, end))
      : new Uint8Array(await input.slice(offset, end).arrayBuffer());
    signal?.throwIfAborted();

    const digestPromise = globalThis.crypto.subtle.digest("SHA-256", chunkBytes);
    wholeFileHasher?.update(chunkBytes);
    const chunkHash = bytesToHex(new Uint8Array(await digestPromise));
    signal?.throwIfAborted();

    chunks.push({
      index,
      hash: chunkHash,
      offset,
      sizeBytes: len,
      slice: () => (isBytes ? input.subarray(offset, end) : input.slice(offset, end)),
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
