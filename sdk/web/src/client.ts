import type { MessageInitShape } from "@bufbuild/protobuf";
import {
  createClient,
  type CallOptions,
  type Client,
  type Transport,
} from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";

import { defaultChunkSizeForNamespace, prepareChunkPlan } from "./chunker.js";
import { MAX_CHUNK_SIZE_BYTES } from "./constants.js";
import { downloadStream, putChunk } from "./dataplane.js";
import { LumaVaultDataPlaneError } from "./errors.js";
import {
  StorageService,
  type CommitObjectRequestSchema,
  type HasChunksResponse,
  type ListObjectsResponse,
  type Namespace,
  type ObjectMetadata,
} from "./gen/lumavault/v1/storage_pb.js";
import { assertValidSha256Hex, sha256Hex } from "./sha256.js";
import type { DownloadStreamOptions } from "./types.js";
import { getChunkUrl, getStreamUrl, normalizeBaseUrl } from "./urls.js";

/** Default number of parallel HTTP `PUT /v1/chunks/{sha256}` workers during `uploadObject`. */
export const DEFAULT_UPLOAD_CONCURRENCY = 2;

export interface LumaVaultClientOptions {
  baseUrl: string;
  transport?: Transport;
  fetch?: typeof globalThis.fetch;
  useBinaryFormat?: boolean;
}

export type UploadPhase = "hashing" | "checking" | "uploading" | "committing";

export interface UploadProgress {
  phase: UploadPhase;
  hashedBytes: number;
  totalBytes: number;
  uploadedChunks: number;
  totalMissingChunks: number;
  uploadedBytes: number;
  totalUploadBytes: number;
}

export interface UploadObjectOptions {
  namespace: Namespace;
  filename?: string;
  mimeType?: string;
  chunkSizeBytes?: number;
  thumbnail?: Blob | Uint8Array;
  /** Set `true` to force a distinct `ObjectMetadata` record (e.g., versioned game save snapshots). */
  skipDedup?: boolean;
  /** Maximum concurrent chunk `PUT` requests (default: `2`). */
  concurrency?: number;
  signal?: AbortSignal;
  headers?: HeadersInit;
  onProgress?: (progress: UploadProgress) => void;
}

export interface UploadObjectResult {
  readonly object: ObjectMetadata;
  readonly deduplicated: boolean;
  readonly uploadedChunks: number;
  readonly skippedChunks: number;
}

export interface ListObjectsOptions {
  namespace: Namespace;
  pageSize?: number;
  pageToken?: string;
}

export interface ListAllObjectsOptions extends CallOptions {
  pageSize?: number;
}

export interface UpdateObjectMetadataFields {
  filename?: string;
  mimeType?: string;
  thumbnailChunkHash?: string;
}

export type DownloadObjectOptions = Omit<DownloadStreamOptions, "fetch">;

function assertValidObjectId(objectId: string): void {
  if (
    typeof objectId !== "string" ||
    objectId.length === 0 ||
    objectId === "." ||
    objectId === ".."
  ) {
    throw new RangeError(`Invalid objectId: "${String(objectId)}"`);
  }
}

/**
 * Builds the immutable content-addressed thumbnail URL (`{baseUrl}/v1/chunks/{thumbnailChunkHash}`),
 * or returns `null` when `thumbnailChunkHash` is empty.
 */
export function getThumbnailUrl(
  baseUrl: string,
  target: Pick<ObjectMetadata, "thumbnailChunkHash"> | string | null | undefined,
): string | null {
  const root = normalizeBaseUrl(baseUrl);
  if (target === null || target === undefined) {
    return null;
  }
  const hash = typeof target === "string" ? target : target.thumbnailChunkHash;
  return hash ? getChunkUrl(root, hash) : null;
}

/**
 * High-level LumaVault client uniting the Connect-RPC `StorageService` Control Plane
 * with the raw streaming HTTP Data Plane.
 */
export class LumaVaultClient {
  readonly baseUrl: string;
  readonly rpc: Client<typeof StorageService>;
  private readonly fetchOverride?: typeof globalThis.fetch;

  constructor(options: LumaVaultClientOptions) {
    this.baseUrl = normalizeBaseUrl(options.baseUrl);
    this.fetchOverride = options.fetch;
    const transport =
      options.transport ??
      createConnectTransport({
        baseUrl: this.baseUrl,
        useBinaryFormat: options.useBinaryFormat,
        fetch: options.fetch,
      });
    this.rpc = createClient(StorageService, transport);
  }

  /**
   * Slices and hashes `data`, checks `HasChunks`, uploads unique missing chunks via a bounded
   * worker pool, and commits the full ordered manifest via `CommitObject`.
   */
  async uploadObject(
    data: Blob | Uint8Array,
    options: UploadObjectOptions,
  ): Promise<UploadObjectResult> {
    const {
      namespace,
      chunkSizeBytes,
      thumbnail,
      skipDedup = false,
      concurrency = DEFAULT_UPLOAD_CONCURRENCY,
      signal,
      headers,
      onProgress,
    } = options;

    signal?.throwIfAborted();
    defaultChunkSizeForNamespace(namespace);

    if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
      throw new RangeError(
        `concurrency must be a positive integer, got ${String(concurrency)}`,
      );
    }

    if (thumbnail !== undefined) {
      if (!(thumbnail instanceof Uint8Array) && !(thumbnail instanceof Blob)) {
        throw new TypeError("thumbnail must be a Blob or Uint8Array");
      }
      const thumbSize =
        thumbnail instanceof Uint8Array ? thumbnail.byteLength : thumbnail.size;
      if (thumbSize === 0) {
        throw new RangeError("thumbnail must not be empty");
      }
      if (thumbSize > MAX_CHUNK_SIZE_BYTES) {
        throw new LumaVaultDataPlaneError(
          "PAYLOAD_TOO_LARGE",
          `Thumbnail payload (${thumbSize} bytes) exceeds maximum chunk size (${MAX_CHUNK_SIZE_BYTES} bytes)`,
        );
      }
    }

    const isFile = typeof File !== "undefined" && data instanceof File;
    const filename = options.filename ?? (isFile ? data.name : "");
    const mimeType = options.mimeType ?? (data instanceof Blob ? data.type : "");

    const emit = (
      phase: UploadPhase,
      hashedBytes: number,
      totalBytes: number,
      uploadedChunks: number,
      totalMissingChunks: number,
      uploadedBytes: number,
      totalUploadBytes: number,
    ): void => {
      onProgress?.({
        phase,
        hashedBytes,
        totalBytes,
        uploadedChunks,
        totalMissingChunks,
        uploadedBytes,
        totalUploadBytes,
      });
    };

    const plan = await prepareChunkPlan(data, {
      namespace,
      chunkSizeBytes,
      signal,
      onProgress: (p) =>
        emit("hashing", p.hashedBytes, p.totalBytes, 0, 0, 0, 0),
    });

    const thumbnailChunkHash =
      thumbnail !== undefined ? await sha256Hex(thumbnail, signal) : "";

    // Deduplicate identical chunk payloads (within the file and against any thumbnail) before RPC/HTTP calls.
    const uniqueChunks = new Map<
      string,
      { sizeBytes: number; slice: () => Blob | Uint8Array }
    >();
    for (const chunk of plan.chunks) {
      if (!uniqueChunks.has(chunk.hash)) {
        uniqueChunks.set(chunk.hash, {
          sizeBytes: chunk.sizeBytes,
          slice: () => chunk.slice(),
        });
      }
    }
    if (thumbnail !== undefined && !uniqueChunks.has(thumbnailChunkHash)) {
      const thumbSize =
        thumbnail instanceof Uint8Array ? thumbnail.byteLength : thumbnail.size;
      uniqueChunks.set(thumbnailChunkHash, {
        sizeBytes: thumbSize,
        slice: () => thumbnail,
      });
    }

    const candidateHashes = Array.from(uniqueChunks.keys());
    const callOptions: CallOptions = { signal, headers };

    let uploadedChunks = 0;
    let skippedChunks = 0;
    let uploadedBytes = 0;
    let totalUploadBytes = 0;
    const missingHashes: string[] = [];

    if (candidateHashes.length > 0) {
      emit("checking", plan.sizeBytes, plan.sizeBytes, 0, 0, 0, 0);
      const hasRes = await this.hasChunks(candidateHashes, callOptions);

      const seenMissing = new Set<string>();
      for (const hash of hasRes.missingChunkHashes) {
        if (!uniqueChunks.has(hash)) {
          throw new Error(`Server returned unexpected missing chunk hash "${hash}"`);
        }
        if (!seenMissing.has(hash)) {
          seenMissing.add(hash);
          missingHashes.push(hash);
        }
      }

      skippedChunks = candidateHashes.length - missingHashes.length;
      totalUploadBytes = missingHashes.reduce(
        (sum, hash) => sum + uniqueChunks.get(hash)!.sizeBytes,
        0,
      );

      if (missingHashes.length > 0) {
        emit(
          "uploading",
          plan.sizeBytes,
          plan.sizeBytes,
          0,
          missingHashes.length,
          0,
          totalUploadBytes,
        );

        const poolController = new AbortController();
        const onCallerAbort = () => poolController.abort(signal?.reason);
        if (signal) {
          if (signal.aborted) {
            poolController.abort(signal.reason);
          } else {
            signal.addEventListener("abort", onCallerAbort, { once: true });
          }
        }

        let nextIndex = 0;
        let firstError: unknown;
        const workerCount = Math.min(concurrency, missingHashes.length);

        const runWorker = async (): Promise<void> => {
          while (!poolController.signal.aborted) {
            const idx = nextIndex++;
            if (idx >= missingHashes.length) {
              return;
            }
            const hash = missingHashes[idx]!;
            const entry = uniqueChunks.get(hash)!;
            try {
              await putChunk(this.baseUrl, hash, entry.slice(), {
                fetch: this.fetchOverride,
                signal: poolController.signal,
              });
              uploadedChunks++;
              uploadedBytes += entry.sizeBytes;
              emit(
                "uploading",
                plan.sizeBytes,
                plan.sizeBytes,
                uploadedChunks,
                missingHashes.length,
                uploadedBytes,
                totalUploadBytes,
              );
            } catch (err) {
              if (firstError === undefined) {
                firstError = err;
                poolController.abort(err);
              }
              return;
            }
          }
        };

        try {
          await Promise.all(Array.from({ length: workerCount }, () => runWorker()));
        } finally {
          signal?.removeEventListener("abort", onCallerAbort);
        }

        signal?.throwIfAborted();
        if (firstError !== undefined) {
          throw firstError;
        }
      }
    }

    emit(
      "committing",
      plan.sizeBytes,
      plan.sizeBytes,
      uploadedChunks,
      missingHashes.length,
      uploadedBytes,
      totalUploadBytes,
    );

    const committed = await this.commitObject(
      {
        namespace,
        filename,
        mimeType,
        sizeBytes: BigInt(plan.sizeBytes),
        chunkSizeBytes: plan.chunkSizeBytes,
        sha256Digest: plan.sha256Digest,
        chunkHashes: plan.chunks.map((c) => c.hash),
        thumbnailChunkHash,
        skipDedup,
      },
      callOptions,
    );

    return {
      object: committed.object,
      deduplicated: committed.deduplicated,
      uploadedChunks,
      skippedChunks,
    };
  }

  /** Checks which candidate SHA-256 chunk hashes are missing from `ChunkStore`. */
  async hasChunks(
    chunkHashes: readonly string[],
    options?: CallOptions,
  ): Promise<HasChunksResponse> {
    for (const hash of chunkHashes) {
      assertValidSha256Hex(hash, "chunkHash");
    }
    return this.rpc.hasChunks({ chunkHashes: [...chunkHashes] }, options);
  }

  /** Commits an object manifest after all referenced chunks are present in `ChunkStore`. */
  async commitObject(
    request: MessageInitShape<typeof CommitObjectRequestSchema>,
    options?: CallOptions,
  ): Promise<{ object: ObjectMetadata; deduplicated: boolean }> {
    defaultChunkSizeForNamespace(request.namespace ?? (0 as Namespace));
    const res = await this.rpc.commitObject(request, options);
    if (!res.object) {
      throw new Error("CommitObject response missing object metadata");
    }
    return { object: res.object, deduplicated: res.deduplicated };
  }

  /** Retrieves a single `ObjectMetadata` manifest by ID. */
  async getObject(objectId: string, options?: CallOptions): Promise<ObjectMetadata> {
    assertValidObjectId(objectId);
    const res = await this.rpc.getObject({ objectId }, options);
    if (!res.object) {
      throw new Error(`GetObject response missing object metadata for "${objectId}"`);
    }
    return res.object;
  }

  /** Lists a single page of objects within `request.namespace`. */
  async listObjects(
    request: ListObjectsOptions,
    options?: CallOptions,
  ): Promise<ListObjectsResponse> {
    defaultChunkSizeForNamespace(request.namespace);
    return this.rpc.listObjects(request, options);
  }

  /** Automatically follows `nextPageToken` cursors until all objects in `namespace` are yielded. */
  async *listAllObjects(
    namespace: Namespace,
    options: ListAllObjectsOptions = {},
  ): AsyncGenerator<ObjectMetadata, void, undefined> {
    defaultChunkSizeForNamespace(namespace);
    const { pageSize, ...callOptions } = options;
    let pageToken = "";
    const seenTokens = new Set<string>();

    while (true) {
      callOptions.signal?.throwIfAborted();
      const res = await this.rpc.listObjects(
        { namespace, pageSize, pageToken },
        callOptions,
      );

      for (const obj of res.objects) {
        yield obj;
      }

      if (!res.nextPageToken) {
        return;
      }
      if (seenTokens.has(res.nextPageToken)) {
        throw new Error(
          `Detected repeating nextPageToken "${res.nextPageToken}" in ListObjects`,
        );
      }
      seenTokens.add(res.nextPageToken);
      pageToken = res.nextPageToken;
    }
  }

  /**
   * Partially updates mutable storage-level metadata fields (`filename`, `mime_type`,
   * `thumbnail_chunk_hash`) with an auto-generated `FieldMask`, rejecting empty updates locally.
   */
  async updateObjectMetadata(
    objectId: string,
    fields: UpdateObjectMetadataFields,
    options?: CallOptions,
  ): Promise<ObjectMetadata> {
    assertValidObjectId(objectId);
    if (typeof fields !== "object" || fields === null) {
      throw new TypeError("fields must be a non-null object");
    }

    const paths: string[] = [];
    if (fields.filename !== undefined) {
      paths.push("filename");
    }
    if (fields.mimeType !== undefined) {
      paths.push("mime_type");
    }
    if (fields.thumbnailChunkHash !== undefined) {
      if (fields.thumbnailChunkHash !== "") {
        assertValidSha256Hex(fields.thumbnailChunkHash, "thumbnailChunkHash");
      }
      paths.push("thumbnail_chunk_hash");
    }

    if (paths.length === 0) {
      throw new RangeError(
        "updateObjectMetadata requires at least one mutable field (filename, mimeType, or thumbnailChunkHash)",
      );
    }

    const res = await this.rpc.updateObjectMetadata(
      {
        object: {
          id: objectId,
          filename: fields.filename,
          mimeType: fields.mimeType,
          thumbnailChunkHash: fields.thumbnailChunkHash,
        },
        updateMask: { paths },
      },
      options,
    );

    if (!res.object) {
      throw new Error(
        `UpdateObjectMetadata response missing object metadata for "${objectId}"`,
      );
    }
    return res.object;
  }

  /** Deletes an object's metadata manifest by ID. */
  async deleteObject(objectId: string, options?: CallOptions): Promise<void> {
    assertValidObjectId(objectId);
    await this.rpc.deleteObject({ objectId }, options);
  }

  /**
   * Downloads and SHA-256 verifies a full object stream via `GET /v1/stream/{id}` without
   * issuing an extra `GetObject` RPC (using `target.sha256Digest` when `ObjectMetadata` is passed,
   * or falling back to strong `ETag` verification when an `objectId` string is passed).
   */
  async downloadObject(
    target: string | Pick<ObjectMetadata, "id" | "sha256Digest">,
    options: DownloadObjectOptions = {},
  ): Promise<Uint8Array> {
    const isStringTarget = typeof target === "string";
    if (!isStringTarget && (typeof target !== "object" || target === null)) {
      throw new TypeError("target must be an objectId string or ObjectMetadata");
    }
    const objectId = isStringTarget ? target : target.id;
    const expectedSha256 = isStringTarget
      ? options.expectedSha256
      : (options.expectedSha256 ?? target.sha256Digest);

    return downloadStream(this.baseUrl, objectId, {
      fetch: this.fetchOverride,
      ...options,
      expectedSha256,
    });
  }

  /** Builds the byte-range stream URL (`{baseUrl}/v1/stream/{objectId}`) for `<video>`/`<audio>`. */
  getStreamUrl(target: string | Pick<ObjectMetadata, "id">): string {
    const objectId = typeof target === "string" ? target : target?.id;
    return getStreamUrl(this.baseUrl, objectId);
  }

  /** Builds the content-addressed chunk URL (`{baseUrl}/v1/chunks/{sha256}`). */
  getChunkUrl(sha256: string): string {
    return getChunkUrl(this.baseUrl, sha256);
  }

  /** Builds the thumbnail URL (`{baseUrl}/v1/chunks/{thumbnailChunkHash}`), or `null` if unset. */
  getThumbnailUrl(
    target: Pick<ObjectMetadata, "thumbnailChunkHash"> | string | null | undefined,
  ): string | null {
    return getThumbnailUrl(this.baseUrl, target);
  }
}
