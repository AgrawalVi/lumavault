import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";

import { create } from "@bufbuild/protobuf";
import { Code, ConnectError, createRouterTransport } from "@connectrpc/connect";

import {
  EMPTY_SHA256_DIGEST,
  LumaVaultClient,
  LumaVaultDataPlaneError,
  MIN_CHUNK_SIZE_BYTES,
  Namespace,
  ObjectMetadataSchema,
  StorageService,
  getThumbnailUrl,
  type CommitObjectRequest,
  type ObjectMetadata,
  type UploadPhase,
  type UploadProgress,
} from "./index.js";

function nodeSha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function makeBytes(length: number, seed: number): Uint8Array {
  const out = new Uint8Array(length);
  let state = seed >>> 0;
  for (let i = 0; i < length; i++) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    out[i] = (state >>> 24) & 0xff;
  }
  return out;
}

function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, p) => sum + p.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.byteLength;
  }
  return out;
}

/**
 * In-memory fake LumaVault Gateway pairing a real `createRouterTransport` Connect-RPC router
 * with a mock HTTP Data Plane (`PUT/GET /v1/chunks/{sha256}` and `GET /v1/stream/{id}`).
 */
function createFakeGateway(hooks?: {
  onPutChunk?: (hash: string, body: Uint8Array, signal?: AbortSignal | null) => Promise<Response | void>;
  includeStreamEtag?: boolean;
}) {
  const chunks = new Map<string, Uint8Array>();
  const objects = new Map<string, ObjectMetadata>();
  const dedupIndex = new Map<string, string>();
  let nextId = 1;

  const stats = {
    hasChunksCalls: [] as string[][],
    commitRequests: [] as CommitObjectRequest[],
    putChunkHashes: [] as string[],
    getObjectCalls: [] as string[],
    listObjectsCalls: [] as Array<{ namespace: Namespace; pageSize: number; pageToken: string }>,
    updateRequests: [] as Array<{ id: string; paths: string[]; object: ObjectMetadata }>,
    deleteCalls: [] as string[],
    activePuts: 0,
    peakPuts: 0,
  };

  const transport = createRouterTransport((router) => {
    router.service(StorageService, {
      hasChunks(req) {
        stats.hasChunksCalls.push([...req.chunkHashes]);
        const missingChunkHashes = req.chunkHashes.filter((h) => !chunks.has(h));
        return { missingChunkHashes };
      },

      commitObject(req) {
        stats.commitRequests.push(req);
        for (const h of req.chunkHashes) {
          if (!chunks.has(h)) {
            throw new ConnectError(`missing chunk ${h}`, Code.FailedPrecondition);
          }
        }
        if (req.thumbnailChunkHash && !chunks.has(req.thumbnailChunkHash)) {
          throw new ConnectError(
            `missing thumbnail chunk ${req.thumbnailChunkHash}`,
            Code.FailedPrecondition,
          );
        }

        const key = `${req.namespace}:${req.sha256Digest}`;
        if (!req.skipDedup) {
          const existingId = dedupIndex.get(key);
          const existing = existingId ? objects.get(existingId) : undefined;
          if (existing) {
            return { object: existing, deduplicated: true };
          }
        }

        const id = `obj-${nextId++}`;
        const obj = create(ObjectMetadataSchema, {
          id,
          namespace: req.namespace,
          filename: req.filename,
          mimeType: req.mimeType,
          sizeBytes: req.sizeBytes,
          chunkSizeBytes: req.chunkSizeBytes,
          sha256Digest: req.sha256Digest,
          chunkHashes: [...req.chunkHashes],
          thumbnailChunkHash: req.thumbnailChunkHash,
        });
        objects.set(id, obj);
        if (!req.skipDedup || !dedupIndex.has(key)) {
          dedupIndex.set(key, id);
        }
        return { object: obj, deduplicated: false };
      },

      getObject(req) {
        stats.getObjectCalls.push(req.objectId);
        const obj = objects.get(req.objectId);
        if (!obj) {
          throw new ConnectError("not found", Code.NotFound);
        }
        return { object: obj };
      },

      listObjects(req) {
        stats.listObjectsCalls.push({
          namespace: req.namespace,
          pageSize: req.pageSize,
          pageToken: req.pageToken,
        });
        const all = Array.from(objects.values()).filter(
          (o) => o.namespace === req.namespace,
        );
        const start = req.pageToken ? Number(req.pageToken) : 0;
        const size = req.pageSize > 0 ? req.pageSize : 50;
        const slice = all.slice(start, start + size);
        const nextPageToken = start + size < all.length ? String(start + size) : "";
        return { objects: slice, nextPageToken };
      },

      updateObjectMetadata(req) {
        const id = req.object?.id ?? "";
        const existing = objects.get(id);
        if (!existing) {
          throw new ConnectError("not found", Code.NotFound);
        }
        const paths = [...(req.updateMask?.paths ?? [])];
        if (paths.length === 0) {
          throw new ConnectError("empty update_mask", Code.InvalidArgument);
        }
        const updated = create(ObjectMetadataSchema, {
          ...existing,
          chunkHashes: [...existing.chunkHashes],
        });
        for (const path of paths) {
          if (path === "filename") {
            updated.filename = req.object?.filename ?? "";
          } else if (path === "mime_type") {
            updated.mimeType = req.object?.mimeType ?? "";
          } else if (path === "thumbnail_chunk_hash") {
            updated.thumbnailChunkHash = req.object?.thumbnailChunkHash ?? "";
          } else {
            throw new ConnectError(`unsupported path ${path}`, Code.InvalidArgument);
          }
        }
        objects.set(id, updated);
        stats.updateRequests.push({ id, paths, object: updated });
        return { object: updated };
      },

      deleteObject(req) {
        stats.deleteCalls.push(req.objectId);
        if (!objects.delete(req.objectId)) {
          throw new ConnectError("not found", Code.NotFound);
        }
        return {};
      },
    });
  });

  const mockFetch: typeof globalThis.fetch = async (input, init) => {
    const url = new URL(String(input));
    const method = (init?.method ?? "GET").toUpperCase();

    if (url.pathname.startsWith("/v1/chunks/")) {
      const hash = url.pathname.slice("/v1/chunks/".length);
      if (method === "PUT") {
        stats.activePuts++;
        stats.peakPuts = Math.max(stats.peakPuts, stats.activePuts);
        try {
          init?.signal?.throwIfAborted();
          const body = new Uint8Array(await new Response(init?.body).arrayBuffer());
          if (hooks?.onPutChunk) {
            const custom = await hooks.onPutChunk(hash, body, init?.signal);
            if (custom) {
              return custom;
            }
          } else {
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
          init?.signal?.throwIfAborted();

          const actual = nodeSha256(body);
          if (actual !== hash) {
            return new Response('{"error":"sha256 digest mismatch"}', { status: 400 });
          }
          chunks.set(hash, body);
          stats.putChunkHashes.push(hash);
          return new Response(
            JSON.stringify({ sha256: hash, size_bytes: body.byteLength }),
            { status: 201, headers: { "Content-Type": "application/json" } },
          );
        } finally {
          stats.activePuts--;
        }
      }
      if (method === "GET") {
        const data = chunks.get(hash);
        if (!data) {
          return new Response("not found", { status: 404 });
        }
        return new Response(new Uint8Array(data), {
          status: 200,
          headers: { ETag: `"${hash}"` },
        });
      }
    }

    if (url.pathname.startsWith("/v1/stream/") && method === "GET") {
      const objectId = decodeURIComponent(url.pathname.slice("/v1/stream/".length));
      const obj = objects.get(objectId);
      if (!obj) {
        return new Response("not found", { status: 404 });
      }
      const parts = obj.chunkHashes.map((h) => chunks.get(h)!);
      const merged = concatBytes(parts);
      const headers = new Headers({
        "Content-Length": String(merged.byteLength),
      });
      if (hooks?.includeStreamEtag !== false) {
        headers.set("ETag", `"${obj.sha256Digest}"`);
      }
      return new Response(new Uint8Array(merged), { status: 200, headers });
    }

    return new Response("not found", { status: 404 });
  };

  const client = new LumaVaultClient({
    baseUrl: "http://localhost:8080///",
    transport,
    fetch: mockFetch,
  });

  return { client, chunks, objects, stats, transport, mockFetch };
}

describe("LumaVaultClient setup and URL helpers", () => {
  it("normalizes baseUrl and builds stream, chunk, and nullable thumbnail URLs", async () => {
    const { client } = createFakeGateway();
    assert.equal(client.baseUrl, "http://localhost:8080");
    assert.equal(
      client.getStreamUrl("obj-42"),
      "http://localhost:8080/v1/stream/obj-42",
    );
    assert.equal(
      client.getChunkUrl(EMPTY_SHA256_DIGEST),
      `http://localhost:8080/v1/chunks/${EMPTY_SHA256_DIGEST}`,
    );

    assert.equal(client.getThumbnailUrl(null), null);
    assert.equal(client.getThumbnailUrl(""), null);
    assert.equal(client.getThumbnailUrl({ thumbnailChunkHash: "" }), null);
    assert.equal(getThumbnailUrl("http://localhost:8080/", { thumbnailChunkHash: "" }), null);
    assert.equal(
      client.getThumbnailUrl({ thumbnailChunkHash: EMPTY_SHA256_DIGEST }),
      `http://localhost:8080/v1/chunks/${EMPTY_SHA256_DIGEST}`,
    );

    // Verify default createConnectTransport path respects custom fetch and useBinaryFormat.
    let seenUrl = "";
    const directClient = new LumaVaultClient({
      baseUrl: "http://localhost:9090/",
      useBinaryFormat: false,
      fetch: async (input) => {
        seenUrl = String(input);
        return new Response(JSON.stringify({ missingChunkHashes: [] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      },
    });
    const hasRes = await directClient.hasChunks([EMPTY_SHA256_DIGEST]);
    assert.deepEqual(hasRes.missingChunkHashes, []);
    assert.equal(
      seenUrl,
      "http://localhost:9090/lumavault.v1.StorageService/HasChunks",
    );
  });
});

describe("LumaVaultClient.uploadObject", () => {
  it("uploads a multi-chunk File with bounded concurrency=2, File metadata inference, and 4-phase progress", async () => {
    const { client, stats } = createFakeGateway();

    const c0 = makeBytes(MIN_CHUNK_SIZE_BYTES, 10);
    const c1 = makeBytes(MIN_CHUNK_SIZE_BYTES, 20);
    const c2 = makeBytes(MIN_CHUNK_SIZE_BYTES, 30);
    const c3 = makeBytes(MIN_CHUNK_SIZE_BYTES, 40);
    const c4 = makeBytes(512 * 1024, 50);
    const fullBytes = concatBytes([c0, c1, c2, c3, c4]);
    const file = new File([fullBytes as Uint8Array<ArrayBuffer>], "clip.mov", {
      type: "video/quicktime",
    });

    const events: UploadProgress[] = [];
    const res = await client.uploadObject(file, {
      namespace: Namespace.PHOTOS,
      onProgress: (p) => events.push({ ...p }),
    });

    assert.equal(stats.peakPuts, 2);
    assert.equal(stats.putChunkHashes.length, 5);
    assert.equal(res.deduplicated, false);
    assert.equal(res.uploadedChunks, 5);
    assert.equal(res.skippedChunks, 0);
    assert.equal(res.object.filename, "clip.mov");
    assert.equal(res.object.mimeType, "video/quicktime");
    assert.equal(res.object.sizeBytes, BigInt(fullBytes.byteLength));
    assert.equal(res.object.chunkSizeBytes, MIN_CHUNK_SIZE_BYTES);
    assert.equal(res.object.sha256Digest, nodeSha256(fullBytes));
    assert.deepEqual(res.object.chunkHashes, [
      nodeSha256(c0),
      nodeSha256(c1),
      nodeSha256(c2),
      nodeSha256(c3),
      nodeSha256(c4),
    ]);

    const distinctPhases = events.reduce<UploadPhase[]>((acc, e) => {
      if (acc[acc.length - 1] !== e.phase) {
        acc.push(e.phase);
      }
      return acc;
    }, []);
    assert.deepEqual(distinctPhases, ["hashing", "checking", "uploading", "committing"]);
    const lastEvent = events[events.length - 1]!;
    assert.equal(lastEvent.phase, "committing");
    assert.equal(lastEvent.uploadedChunks, 5);
    assert.equal(lastEvent.totalMissingChunks, 5);
    assert.equal(lastEvent.uploadedBytes, fullBytes.byteLength);
    assert.equal(lastEvent.totalUploadBytes, fullBytes.byteLength);
  });

  it("handles partial deduplication (1 of 4 chunks missing) and 100% deduplication", async () => {
    const { client, chunks, stats } = createFakeGateway();

    const parts = [
      makeBytes(MIN_CHUNK_SIZE_BYTES, 1),
      makeBytes(MIN_CHUNK_SIZE_BYTES, 2),
      makeBytes(MIN_CHUNK_SIZE_BYTES, 3),
      makeBytes(MIN_CHUNK_SIZE_BYTES, 4),
    ];
    const hashes = parts.map(nodeSha256);

    // Pre-populate chunks 0, 1, and 3; only chunk 2 is missing.
    chunks.set(hashes[0]!, parts[0]!);
    chunks.set(hashes[1]!, parts[1]!);
    chunks.set(hashes[3]!, parts[3]!);

    const payload = concatBytes(parts);
    const partial = await client.uploadObject(payload, {
      namespace: Namespace.GAMES,
      filename: "pokemon.nds",
      mimeType: "application/x-nds-rom",
    });

    assert.deepEqual(stats.hasChunksCalls, [hashes]);
    assert.deepEqual(stats.putChunkHashes, [hashes[2]!]);
    assert.equal(partial.deduplicated, false);
    assert.equal(partial.uploadedChunks, 1);
    assert.equal(partial.skippedChunks, 3);
    assert.deepEqual(partial.object.chunkHashes, hashes);

    // Re-uploading the exact same ROM hits 100% chunk dedup + object dedup.
    const fullDedup = await client.uploadObject(payload, {
      namespace: Namespace.GAMES,
      filename: "pokemon-copy.nds",
    });

    assert.equal(stats.putChunkHashes.length, 1); // Zero additional PUTs!
    assert.equal(fullDedup.deduplicated, true);
    assert.equal(fullDedup.uploadedChunks, 0);
    assert.equal(fullDedup.skippedChunks, 4);
    assert.equal(fullDedup.object.id, partial.object.id);
  });

  it("deduplicates intra-file repeated chunks before HasChunks and putChunk while committing full chunk_hashes", async () => {
    const { client, stats } = createFakeGateway();

    const chunkA = makeBytes(MIN_CHUNK_SIZE_BYTES, 101);
    const chunkB = makeBytes(MIN_CHUNK_SIZE_BYTES, 202);
    const hashA = nodeSha256(chunkA);
    const hashB = nodeSha256(chunkB);

    // Pattern: [A, B, A, A] -> 2 unique chunks, 4 ordered manifest entries.
    const payload = concatBytes([chunkA, chunkB, chunkA, chunkA]);
    const res = await client.uploadObject(payload, {
      namespace: Namespace.PHOTOS,
      filename: " burst.raw ",
    });

    assert.deepEqual(stats.hasChunksCalls, [[hashA, hashB]]);
    assert.equal(stats.putChunkHashes.length, 2);
    assert.deepEqual(new Set(stats.putChunkHashes), new Set([hashA, hashB]));
    assert.equal(res.uploadedChunks, 2);
    assert.equal(res.skippedChunks, 0);
    assert.deepEqual(res.object.chunkHashes, [hashA, hashB, hashA, hashA]);
  });

  it("skips HasChunks and chunk uploads on 0-byte files without thumbnails", async () => {
    const { client, stats } = createFakeGateway();

    const phases: UploadPhase[] = [];
    const res = await client.uploadObject(new Uint8Array(0), {
      namespace: Namespace.PHOTOS,
      filename: "empty.bin",
      onProgress: (p) => phases.push(p.phase),
    });

    assert.equal(stats.hasChunksCalls.length, 0);
    assert.equal(stats.putChunkHashes.length, 0);
    assert.equal(res.uploadedChunks, 0);
    assert.equal(res.skippedChunks, 0);
    assert.equal(res.object.sizeBytes, 0n);
    assert.equal(res.object.sha256Digest, EMPTY_SHA256_DIGEST);
    assert.deepEqual(res.object.chunkHashes, []);
    assert.deepEqual(phases, ["hashing", "committing"]);
  });

  it("supports skipDedup: true for distinct versioned game save snapshots sharing identical bytes", async () => {
    const { client, stats } = createFakeGateway();

    const saveBytes = makeBytes(128 * 1024, 777);
    const v1 = await client.uploadObject(saveBytes, {
      namespace: Namespace.GAMES,
      filename: "emerald-v1.sav",
      skipDedup: true,
    });
    const v2 = await client.uploadObject(saveBytes, {
      namespace: Namespace.GAMES,
      filename: "emerald-v2.sav",
      skipDedup: true,
    });

    assert.equal(stats.putChunkHashes.length, 1); // Chunk uploaded only once!
    assert.equal(v1.deduplicated, false);
    assert.equal(v2.deduplicated, false);
    assert.notEqual(v1.object.id, v2.object.id);
    assert.equal(v2.uploadedChunks, 0);
    assert.equal(v2.skippedChunks, 1);
    assert.equal(stats.commitRequests[0]!.skipDedup, true);
    assert.equal(stats.commitRequests[1]!.skipDedup, true);
  });

  it("uploads optional thumbnail chunk alongside file chunks and populates thumbnailChunkHash", async () => {
    const { client, stats } = createFakeGateway();

    const photoBytes = makeBytes(64 * 1024, 11);
    const thumbBytes = makeBytes(4 * 1024, 22);
    const photoHash = nodeSha256(photoBytes);
    const thumbHash = nodeSha256(thumbBytes);

    const res = await client.uploadObject(photoBytes, {
      namespace: Namespace.PHOTOS,
      filename: "IMG_0001.HEIC",
      mimeType: "image/heic",
      thumbnail: thumbBytes,
    });

    assert.deepEqual(stats.hasChunksCalls, [[photoHash, thumbHash]]);
    assert.deepEqual(new Set(stats.putChunkHashes), new Set([photoHash, thumbHash]));
    assert.equal(res.uploadedChunks, 2);
    assert.equal(res.object.thumbnailChunkHash, thumbHash);
    assert.equal(
      client.getThumbnailUrl(res.object),
      `http://localhost:8080/v1/chunks/${thumbHash}`,
    );

    // A 0-byte placeholder with a non-empty thumbnail still checks and uploads the thumbnail.
    const newThumb = makeBytes(2 * 1024, 33);
    const newThumbHash = nodeSha256(newThumb);
    const emptyWithThumb = await client.uploadObject(new Uint8Array(0), {
      namespace: Namespace.PHOTOS,
      thumbnail: newThumb,
    });
    assert.equal(emptyWithThumb.uploadedChunks, 1);
    assert.equal(emptyWithThumb.object.thumbnailChunkHash, newThumbHash);
  });

  it("aborts in-flight sibling workers when a chunk upload fails and skips CommitObject", async () => {
    const c0 = makeBytes(MIN_CHUNK_SIZE_BYTES, 1);
    const c1 = makeBytes(MIN_CHUNK_SIZE_BYTES, 2);
    const c2 = makeBytes(MIN_CHUNK_SIZE_BYTES, 3);
    const h0 = nodeSha256(c0);
    const h1 = nodeSha256(c1);

    let siblingAborted = false;
    let startedChunks = 0;

    const { client, stats } = createFakeGateway({
      async onPutChunk(hash, _body, signal) {
        startedChunks++;
        if (hash === h0) {
          await new Promise((resolve) => setTimeout(resolve, 10));
          return new Response("disk full", { status: 500 });
        }
        if (hash === h1) {
          await new Promise<void>((_resolve, reject) => {
            signal?.addEventListener(
              "abort",
              () => {
                siblingAborted = true;
                reject(signal.reason);
              },
              { once: true },
            );
          });
        }
      },
    });

    await assert.rejects(
      () =>
        client.uploadObject(concatBytes([c0, c1, c2]), {
          namespace: Namespace.PHOTOS,
          concurrency: 2,
        }),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError &&
        err.code === "HTTP_ERROR" &&
        err.status === 500,
    );

    assert.equal(siblingAborted, true);
    assert.equal(startedChunks, 2); // Chunk 2 was never started after failure!
    assert.equal(stats.commitRequests.length, 0);
  });
});

describe("Control plane helpers, FieldMask updates, pagination, and verified downloads", () => {
  it("builds FieldMask paths automatically in updateObjectMetadata and rejects empty/invalid updates client-side", async () => {
    const { client, chunks, stats } = createFakeGateway();

    const created = await client.uploadObject(makeBytes(1024, 9), {
      namespace: Namespace.PHOTOS,
      filename: "before.jpg",
      mimeType: "image/jpeg",
    });

    // Empty updates fail locally before hitting the RPC layer.
    await assert.rejects(
      () => client.updateObjectMetadata(created.object.id, {}),
      RangeError,
    );
    await assert.rejects(
      () =>
        client.updateObjectMetadata(created.object.id, {
          thumbnailChunkHash: "not-a-sha256",
        }),
      RangeError,
    );
    assert.equal(stats.updateRequests.length, 0);

    // Single-field update.
    const renamed = await client.updateObjectMetadata(created.object.id, {
      filename: "after.jpg",
    });
    assert.equal(renamed.filename, "after.jpg");
    assert.equal(renamed.mimeType, "image/jpeg");
    assert.deepEqual(stats.updateRequests[0]!.paths, ["filename"]);

    // Multi-field update including thumbnailChunkHash, then clearing thumbnailChunkHash with "".
    const thumbBytes = makeBytes(512, 88);
    const thumbHash = nodeSha256(thumbBytes);
    chunks.set(thumbHash, thumbBytes);

    const enriched = await client.updateObjectMetadata(created.object.id, {
      filename: "final.webp",
      mimeType: "image/webp",
      thumbnailChunkHash: thumbHash,
    });
    assert.equal(enriched.filename, "final.webp");
    assert.equal(enriched.mimeType, "image/webp");
    assert.equal(enriched.thumbnailChunkHash, thumbHash);
    assert.deepEqual(stats.updateRequests[1]!.paths, [
      "filename",
      "mime_type",
      "thumbnail_chunk_hash",
    ]);

    const clearedThumb = await client.updateObjectMetadata(created.object.id, {
      thumbnailChunkHash: "",
    });
    assert.equal(clearedThumb.thumbnailChunkHash, "");
    assert.deepEqual(stats.updateRequests[2]!.paths, ["thumbnail_chunk_hash"]);
  });

  it("paginates cleanly across multiple pages with listAllObjects and supports getObject / deleteObject", async () => {
    const { client, stats } = createFakeGateway();

    const ids: string[] = [];
    for (let i = 0; i < 5; i++) {
      const res = await client.uploadObject(makeBytes(256, i + 1), {
        namespace: Namespace.CINEMA,
        filename: `ep-${i + 1}.mkv`,
      });
      ids.push(res.object.id);
    }
    // Upload one object in a different namespace to confirm isolation.
    await client.uploadObject(makeBytes(128, 999), {
      namespace: Namespace.PHOTOS,
      filename: "other.jpg",
    });

    const listedIds: string[] = [];
    for await (const obj of client.listAllObjects(Namespace.CINEMA, { pageSize: 2 })) {
      listedIds.push(obj.id);
    }

    assert.deepEqual(listedIds, ids);
    assert.equal(stats.listObjectsCalls.length, 3); // Pages: [0..1], [2..3], [4]

    const fetched = await client.getObject(ids[0]!);
    assert.equal(fetched.filename, "ep-1.mkv");

    await client.deleteObject(ids[0]!);
    await assert.rejects(
      () => client.getObject(ids[0]!),
      (err: unknown) => err instanceof ConnectError && err.code === Code.NotFound,
    );
  });

  it("verifies downloadObject via ObjectMetadata (without ETag) and via objectId + strong ETag with zero GetObject RPCs", async () => {
    const payload = concatBytes([
      makeBytes(MIN_CHUNK_SIZE_BYTES, 501),
      makeBytes(128 * 1024, 502),
    ]);

    // 1. Via ObjectMetadata even when response omits ETag.
    const noEtagGw = createFakeGateway({ includeStreamEtag: false });
    const uploadedNoEtag = await noEtagGw.client.uploadObject(payload, {
      namespace: Namespace.GAMES,
      filename: "zelda.gba",
    });

    const bytesFromMeta = await noEtagGw.client.downloadObject(uploadedNoEtag.object);
    assert.deepEqual(bytesFromMeta, payload);
    assert.equal(noEtagGw.stats.getObjectCalls.length, 0);

    // 2. Via objectId string using quote-stripped strong ETag header.
    const withEtagGw = createFakeGateway({ includeStreamEtag: true });
    const uploadedWithEtag = await withEtagGw.client.uploadObject(payload, {
      namespace: Namespace.GAMES,
      filename: "zelda.gba",
    });

    const bytesFromId = await withEtagGw.client.downloadObject(uploadedWithEtag.object.id);
    assert.deepEqual(bytesFromId, payload);
    assert.equal(withEtagGw.stats.getObjectCalls.length, 0);
  });
});
