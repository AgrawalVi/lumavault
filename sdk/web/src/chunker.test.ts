import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";

import {
  assertValidChunkSize,
  defaultChunkSizeForNamespace,
  isValidChunkSize,
  prepareChunkPlan,
} from "./chunker.js";
import {
  CINEMA_CHUNK_SIZE_BYTES,
  DEFAULT_CHUNK_SIZE_BYTES,
  EMPTY_SHA256_DIGEST,
  MAX_CHUNK_SIZE_BYTES,
  MIN_CHUNK_SIZE_BYTES,
} from "./constants.js";
import { Namespace } from "./gen/lumavault/v1/storage_pb.js";

function nodeSha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function deterministicBytes(length: number, seed = 1): Uint8Array {
  const out = new Uint8Array(length);
  let state = seed >>> 0;
  for (let i = 0; i < length; i++) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    out[i] = (state >>> 24) & 0xff;
  }
  return out;
}

describe("chunker constants and validators", () => {
  it("exports 4 MiB / 64 MiB chunk size constants and namespace defaults", () => {
    assert.equal(MIN_CHUNK_SIZE_BYTES, 4 * 1024 * 1024);
    assert.equal(DEFAULT_CHUNK_SIZE_BYTES, 4 * 1024 * 1024);
    assert.equal(MAX_CHUNK_SIZE_BYTES, 64 * 1024 * 1024);
    assert.equal(CINEMA_CHUNK_SIZE_BYTES, 64 * 1024 * 1024);

    assert.equal(defaultChunkSizeForNamespace(Namespace.PHOTOS), 4 * 1024 * 1024);
    assert.equal(defaultChunkSizeForNamespace(Namespace.GAMES), 4 * 1024 * 1024);
    assert.equal(defaultChunkSizeForNamespace(Namespace.CINEMA), 64 * 1024 * 1024);
    assert.throws(() => defaultChunkSizeForNamespace(Namespace.UNSPECIFIED), RangeError);
  });

  it("validates chunk sizes within [4 MiB, 64 MiB]", () => {
    assert.equal(isValidChunkSize(MIN_CHUNK_SIZE_BYTES), true);
    assert.equal(isValidChunkSize(16 * 1024 * 1024), true);
    assert.equal(isValidChunkSize(MAX_CHUNK_SIZE_BYTES), true);
    assert.equal(isValidChunkSize(MIN_CHUNK_SIZE_BYTES - 1), false);
    assert.equal(isValidChunkSize(MAX_CHUNK_SIZE_BYTES + 1), false);
    assert.equal(isValidChunkSize(MIN_CHUNK_SIZE_BYTES + 0.5), false);
    assert.throws(() => assertValidChunkSize(1024), RangeError);
  });
});

describe("prepareChunkPlan", () => {
  it("handles 0-byte Blob and Uint8Array inputs cleanly", async () => {
    const progressEvents: Array<{ hashedBytes: number; totalChunks: number }> = [];
    const blobPlan = await prepareChunkPlan(new Blob([]), {
      onProgress: (p) => progressEvents.push({ hashedBytes: p.hashedBytes, totalChunks: p.totalChunks }),
    });

    assert.equal(blobPlan.sizeBytes, 0);
    assert.equal(blobPlan.chunkSizeBytes, DEFAULT_CHUNK_SIZE_BYTES);
    assert.equal(blobPlan.sha256Digest, EMPTY_SHA256_DIGEST);
    assert.deepEqual(blobPlan.chunks, []);
    assert.deepEqual(progressEvents, [{ hashedBytes: 0, totalChunks: 0 }]);

    const bytesPlan = await prepareChunkPlan(new Uint8Array(0), { namespace: Namespace.CINEMA });
    assert.equal(bytesPlan.sizeBytes, 0);
    assert.equal(bytesPlan.chunkSizeBytes, CINEMA_CHUNK_SIZE_BYTES);
    assert.equal(bytesPlan.sha256Digest, EMPTY_SHA256_DIGEST);
    assert.deepEqual(bytesPlan.chunks, []);
  });

  it("hashes single-chunk inputs using the single-chunk fast path", async () => {
    const abc = new TextEncoder().encode("abc");
    const expectedAbc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    const plan = await prepareChunkPlan(new File([abc], "abc.txt", { type: "text/plain" }));
    assert.equal(plan.sizeBytes, 3);
    assert.equal(plan.sha256Digest, expectedAbc);
    assert.equal(plan.chunks.length, 1);
    assert.equal(plan.chunks[0]!.hash, expectedAbc);
    assert.equal(plan.chunks[0]!.offset, 0);
    assert.equal(plan.chunks[0]!.sizeBytes, 3);

    const slice = plan.chunks[0]!.slice();
    assert.ok(slice instanceof Blob);
    assert.deepEqual(new Uint8Array(await slice.arrayBuffer()), abc);
  });

  it("handles exact 4 MiB boundary as a single full chunk", async () => {
    const exact4MiB = deterministicBytes(MIN_CHUNK_SIZE_BYTES, 42);
    const expected = nodeSha256(exact4MiB);

    const plan = await prepareChunkPlan(exact4MiB);
    assert.equal(plan.sizeBytes, MIN_CHUNK_SIZE_BYTES);
    assert.equal(plan.chunks.length, 1);
    assert.equal(plan.chunks[0]!.sizeBytes, MIN_CHUNK_SIZE_BYTES);
    assert.equal(plan.chunks[0]!.hash, expected);
    assert.equal(plan.sha256Digest, expected);
  });

  it("respects non-zero byteOffset Uint8Array views without reading surrounding ArrayBuffer bytes", async () => {
    const backing = new Uint8Array(1024);
    backing.fill(0xff);
    const innerPayload = deterministicBytes(257, 99);
    backing.set(innerPayload, 137);

    const view = new Uint8Array(backing.buffer, 137, innerPayload.byteLength);
    const expected = nodeSha256(innerPayload);

    const plan = await prepareChunkPlan(view);
    assert.equal(plan.sizeBytes, innerPayload.byteLength);
    assert.equal(plan.sha256Digest, expected);
    assert.equal(plan.chunks.length, 1);
    assert.equal(plan.chunks[0]!.hash, expected);

    const slice = plan.chunks[0]!.slice();
    assert.ok(slice instanceof Uint8Array);
    assert.equal(slice.byteOffset, 137);
    assert.equal(slice.byteLength, innerPayload.byteLength);
    assert.deepEqual(slice, innerPayload);
  });

  it("hashes a multi-chunk 10.5 MiB Blob in a single pass with at most one chunk in memory", async () => {
    const totalSize = Math.floor(10.5 * 1024 * 1024); // 4 MiB + 4 MiB + 2.5 MiB
    const part0 = deterministicBytes(MIN_CHUNK_SIZE_BYTES, 1);
    const part1 = deterministicBytes(MIN_CHUNK_SIZE_BYTES, 2);
    const part2 = deterministicBytes(totalSize - 2 * MIN_CHUNK_SIZE_BYTES, 3);

    const expectedWhole = createHash("sha256")
      .update(part0)
      .update(part1)
      .update(part2)
      .digest("hex");

    let activeReads = 0;
    let peakConcurrentReads = 0;
    let arrayBufferReads = 0;

    class TrackedBlob extends Blob {
      override slice(start?: number, end?: number, contentType?: string): Blob {
        const inner = super.slice(start, end, contentType);
        return new Proxy(inner, {
          get(target, prop, receiver) {
            if (prop === "arrayBuffer") {
              return async () => {
                activeReads++;
                arrayBufferReads++;
                peakConcurrentReads = Math.max(peakConcurrentReads, activeReads);
                try {
                  return await target.arrayBuffer();
                } finally {
                  activeReads--;
                }
              };
            }
            const value = Reflect.get(target, prop, receiver);
            return typeof value === "function" ? value.bind(target) : value;
          },
        });
      }
    }

    const trackedBlob = new TrackedBlob([
      part0 as Uint8Array<ArrayBuffer>,
      part1 as Uint8Array<ArrayBuffer>,
      part2 as Uint8Array<ArrayBuffer>,
    ]);
    const progressCalls: number[] = [];

    const plan = await prepareChunkPlan(trackedBlob, {
      namespace: Namespace.PHOTOS,
      onProgress: (p) => progressCalls.push(p.hashedBytes),
    });

    assert.equal(peakConcurrentReads, 1);
    assert.equal(arrayBufferReads, 3);
    assert.equal(plan.sizeBytes, totalSize);
    assert.equal(plan.chunkSizeBytes, MIN_CHUNK_SIZE_BYTES);
    assert.equal(plan.sha256Digest, expectedWhole);
    assert.equal(plan.chunks.length, 3);

    assert.equal(plan.chunks[0]!.hash, nodeSha256(part0));
    assert.equal(plan.chunks[0]!.offset, 0);
    assert.equal(plan.chunks[0]!.sizeBytes, MIN_CHUNK_SIZE_BYTES);

    assert.equal(plan.chunks[1]!.hash, nodeSha256(part1));
    assert.equal(plan.chunks[1]!.offset, MIN_CHUNK_SIZE_BYTES);
    assert.equal(plan.chunks[1]!.sizeBytes, MIN_CHUNK_SIZE_BYTES);

    assert.equal(plan.chunks[2]!.hash, nodeSha256(part2));
    assert.equal(plan.chunks[2]!.offset, 2 * MIN_CHUNK_SIZE_BYTES);
    assert.equal(plan.chunks[2]!.sizeBytes, part2.byteLength);

    assert.deepEqual(progressCalls, [
      MIN_CHUNK_SIZE_BYTES,
      2 * MIN_CHUNK_SIZE_BYTES,
      totalSize,
    ]);

    // Calling slice() creates a lazy view without materializing arrayBuffer().
    const tailView = plan.chunks[2]!.slice();
    assert.equal(arrayBufferReads, 3);
    assert.ok(tailView instanceof Blob);
    assert.equal(tailView.size, part2.byteLength);
  });

  it("supports AbortSignal cancellation before and mid-hashing", async () => {
    const preAborted = AbortSignal.abort(new Error("pre-aborted"));
    await assert.rejects(
      () => prepareChunkPlan(new Uint8Array(16), { signal: preAborted }),
      /pre-aborted/,
    );

    const multiChunk = new Uint8Array(2 * MIN_CHUNK_SIZE_BYTES + 128);
    const controller = new AbortController();
    let seenChunks = 0;

    await assert.rejects(
      () =>
        prepareChunkPlan(multiChunk, {
          signal: controller.signal,
          onProgress: () => {
            seenChunks++;
            controller.abort(new Error("stop-after-first-chunk"));
          },
        }),
      /stop-after-first-chunk/,
    );
    assert.equal(seenChunks, 1);
  });
});
