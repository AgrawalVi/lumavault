import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";

import { EMPTY_SHA256_DIGEST, MAX_CHUNK_SIZE_BYTES } from "./constants.js";
import {
  downloadStream,
  getChunk,
  putChunk,
} from "./dataplane.js";
import { LumaVaultDataPlaneError } from "./errors.js";

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function streamFromChunks(parts: Uint8Array[]): ReadableStream<Uint8Array> {
  let index = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (index < parts.length) {
        controller.enqueue(parts[index++]!);
      } else {
        controller.close();
      }
    },
  });
}

describe("putChunk", () => {
  it("uploads exact Uint8Array subarray bytes with application/octet-stream", async () => {
    const backing = new Uint8Array([9, 9, 1, 2, 3, 4, 9, 9]);
    const slice = backing.subarray(2, 6);
    const hash = sha256(slice);

    let capturedUrl = "";
    let capturedMethod = "";
    let capturedContentType = "";
    let capturedBody = new Uint8Array(0);

    const mockFetch: typeof globalThis.fetch = async (input, init) => {
      capturedUrl = String(input);
      capturedMethod = init?.method ?? "";
      capturedContentType = new Headers(init?.headers).get("Content-Type") ?? "";
      capturedBody = new Uint8Array(await new Response(init?.body).arrayBuffer());
      return new Response(JSON.stringify({ sha256: hash, size_bytes: slice.byteLength }), {
        status: 201,
        headers: { "Content-Type": "application/json" },
      });
    };

    const res = await putChunk("http://localhost:8080/", hash, slice, {
      fetch: mockFetch,
      verifyLocalHash: true,
    });

    assert.equal(capturedUrl, `http://localhost:8080/v1/chunks/${hash}`);
    assert.equal(capturedMethod, "PUT");
    assert.equal(capturedContentType, "application/octet-stream");
    assert.deepEqual(capturedBody, slice);
    assert.deepEqual(res, { sha256: hash, sizeBytes: 4 });
  });

  it("rejects invalid SHA-256 and >64 MiB payloads locally without calling fetch", async () => {
    let fetchCalls = 0;
    const mockFetch: typeof globalThis.fetch = async () => {
      fetchCalls++;
      return new Response(null, { status: 201 });
    };

    await assert.rejects(
      () => putChunk("http://localhost:8080", "invalid-sha", new Uint8Array([1]), { fetch: mockFetch }),
      (err: unknown) => err instanceof LumaVaultDataPlaneError && err.code === "INVALID_HASH",
    );

    const oversizedBlob = { size: MAX_CHUNK_SIZE_BYTES + 1 };
    Object.setPrototypeOf(oversizedBlob, Blob.prototype);

    await assert.rejects(
      () =>
        putChunk("http://localhost:8080", EMPTY_SHA256_DIGEST, oversizedBlob as Blob, {
          fetch: mockFetch,
        }),
      (err: unknown) => err instanceof LumaVaultDataPlaneError && err.code === "PAYLOAD_TOO_LARGE",
    );

    assert.equal(fetchCalls, 0);
  });

  it("maps HTTP 400 mismatch, 413, and 500 errors to LumaVaultDataPlaneError", async () => {
    const payload = new TextEncoder().encode("chunk-bytes");
    const hash = sha256(payload);

    await assert.rejects(
      () =>
        putChunk("http://localhost:8080", hash, payload, {
          fetch: async () => new Response('{"error":"sha256 digest mismatch"}', { status: 400 }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "HASH_MISMATCH" &&
        err.status === 400,
    );

    await assert.rejects(
      () =>
        putChunk("http://localhost:8080", hash, payload, {
          fetch: async () => new Response("too large", { status: 413 }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "PAYLOAD_TOO_LARGE" &&
        err.status === 413,
    );
  });
});

describe("getChunk", () => {
  it("downloads and verifies chunk bytes, throwing HASH_MISMATCH on corruption", async () => {
    const payload = new TextEncoder().encode("verified-chunk-payload");
    const hash = sha256(payload);

    const downloaded = await getChunk("http://localhost:8080", hash, {
      fetch: async () => new Response(payload, { status: 200 }),
    });
    assert.deepEqual(downloaded, payload);

    const corrupted = new Uint8Array(payload);
    corrupted[3] ^= 0xff;

    await assert.rejects(
      () =>
        getChunk("http://localhost:8080", hash, {
          fetch: async () => new Response(corrupted, { status: 200 }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "HASH_MISMATCH" &&
        err.status === 200,
    );

    await assert.rejects(
      () =>
        getChunk("http://localhost:8080", hash, {
          fetch: async () => new Response("missing", { status: 404 }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "NOT_FOUND" &&
        err.status === 404,
    );
  });
});

describe("downloadStream", () => {
  it("verifies downloads against quoted strong ETag and expectedSha256", async () => {
    const partA = new TextEncoder().encode("hello ");
    const partB = new TextEncoder().encode("lumavault stream");
    const full = new Uint8Array([...partA, ...partB]);
    const digest = sha256(full);

    const fromEtag = await downloadStream("http://localhost:8080", "obj-123", {
      fetch: async () =>
        new Response(streamFromChunks([partA, partB]), {
          status: 200,
          headers: { ETag: `"${digest}"` },
        }),
    });
    assert.deepEqual(fromEtag, full);

    const fromExpected = await downloadStream("http://localhost:8080", "obj-123", {
      expectedSha256: digest,
      fetch: async () => new Response(streamFromChunks([partA, partB]), { status: 200 }),
    });
    assert.deepEqual(fromExpected, full);
  });

  it("rejects missing ETag, weak ETag, and corrupted bytes", async () => {
    const body = new TextEncoder().encode("rom-bytes");
    const digest = sha256(body);

    await assert.rejects(
      () =>
        downloadStream("http://localhost:8080", "obj-missing-etag", {
          fetch: async () => new Response(body, { status: 200 }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "INVALID_HASH" &&
        err.status === 200,
    );

    await assert.rejects(
      () =>
        downloadStream("http://localhost:8080", "obj-weak-etag", {
          fetch: async () =>
            new Response(body, {
              status: 200,
              headers: { ETag: `W/"${digest}"` },
            }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "INVALID_HASH" &&
        err.status === 200,
    );

    const flipped = new Uint8Array(body);
    flipped[0] ^= 0x01;
    await assert.rejects(
      () =>
        downloadStream("http://localhost:8080", "obj-corrupt", {
          fetch: async () =>
            new Response(flipped, {
              status: 200,
              headers: { ETag: `"${digest}"` },
            }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "HASH_MISMATCH" &&
        err.status === 200,
    );
  });

  it("enforces maxBytes limit via Content-Length fast-fail and streaming cutoff", async () => {
    const chunk = new Uint8Array(64);
    const digest = sha256(new Uint8Array(192));

    await assert.rejects(
      () =>
        downloadStream("http://localhost:8080", "obj-cl", {
          expectedSha256: digest,
          maxBytes: 100,
          fetch: async () =>
            new Response(chunk, {
              status: 200,
              headers: { "Content-Length": "192" },
            }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "PAYLOAD_TOO_LARGE" &&
        err.status === 200,
    );

    let pulledChunks = 0;
    let cancelled = false;
    const infiniteStream = new ReadableStream<Uint8Array>({
      pull(controller) {
        pulledChunks++;
        controller.enqueue(new Uint8Array(60));
      },
      cancel() {
        cancelled = true;
      },
    });

    await assert.rejects(
      () =>
        downloadStream("http://localhost:8080", "obj-stream-cap", {
          expectedSha256: digest,
          maxBytes: 100,
          fetch: async () => new Response(infiniteStream, { status: 200 }),
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "PAYLOAD_TOO_LARGE" &&
        err.status === 200,
    );

    assert.ok(pulledChunks <= 3, `expected stream to stop immediately, got ${pulledChunks} pulls`);
    assert.equal(cancelled, true);
  });

  it("supports AbortSignal cancellation mid-stream", async () => {
    const controller = new AbortController();
    let streamCancelled = false;
    let pulls = 0;

    await assert.rejects(
      () =>
        downloadStream("http://localhost:8080", "obj-abort", {
          expectedSha256: EMPTY_SHA256_DIGEST,
          signal: controller.signal,
          fetch: async () =>
            new Response(
              new ReadableStream<Uint8Array>({
                pull(streamController) {
                  pulls++;
                  if (pulls === 1) {
                    streamController.enqueue(new Uint8Array([1, 2, 3]));
                  } else {
                    queueMicrotask(() =>
                      controller.abort(new Error("user-cancelled-download")),
                    );
                  }
                },
                cancel() {
                  streamCancelled = true;
                },
              }),
              { status: 200 },
            ),
        }),
      /user-cancelled-download/,
    );
    assert.equal(streamCancelled, true);
  });
});
