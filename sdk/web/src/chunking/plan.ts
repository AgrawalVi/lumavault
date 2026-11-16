import { Code, ConnectError } from "@connectrpc/connect";
import { createSHA256 } from "hash-wasm";
import { toHex } from "../encoding.js";
import { chunkSizeFor } from "./chunk-size.js";
import { toByteSource, type UploadInput } from "./source.js";

/** The manifest fields CommitObject needs, computed locally before any network call. */
export interface ChunkPlan {
  sizeBytes: number;
  chunkSizeBytes: number;
  /** Lowercase hex SHA-256 of the whole input. */
  sha256Digest: string;
  /** Lowercase hex SHA-256 of each chunk, in order. */
  chunkHashes: string[];
}

/**
 * Splits the input into chunks and hashes each chunk and the whole input in one pass.
 * Only one chunk is held in memory at a time, so multi-gigabyte Files are safe.
 */
export async function planChunks(input: UploadInput): Promise<ChunkPlan> {
  const source = toByteSource(input);
  if (source.size === 0) {
    throw new ConnectError("empty files cannot be uploaded", Code.InvalidArgument);
  }

  const chunkSizeBytes = chunkSizeFor(source.size);
  const whole = await createSHA256();
  whole.init();
  const chunkHashes: string[] = [];

  for (let start = 0; start < source.size; start += chunkSizeBytes) {
    const bytes = await source.read(start, Math.min(start + chunkSizeBytes, source.size));
    whole.update(bytes);
    chunkHashes.push(toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))));
  }

  return { sizeBytes: source.size, chunkSizeBytes, sha256Digest: whole.digest("hex"), chunkHashes };
}
