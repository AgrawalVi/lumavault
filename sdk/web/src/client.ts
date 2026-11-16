import type { MessageInitShape } from "@bufbuild/protobuf";
import {
  createClient,
  type CallOptions,
  type Client,
  type Interceptor,
  type Transport,
} from "@connectrpc/connect";
import {
  createConnectTransport,
  type ConnectTransportOptions,
} from "@connectrpc/connect-web";

import { defaultChunkSizeForNamespace, prepareChunkPlan } from "./chunker.js";
import { MAX_CHUNK_SIZE_BYTES } from "./constants.js";
import { downloadStream, putChunk } from "./dataplane.js";
import { LumaVaultDataPlaneError } from "./errors.js";
import {
  StorageService,
  type CommitObjectRequestSchema,
  type HasChunksResponse,
  type ListObjectsRequestSchema,
  type ListObjectsResponse,
  type Namespace,
  type ObjectMetadata,
  type ObjectMetadataSchema,
} from "./gen/lumavault/v1/storage_pb.js";
import { assertValidSha256Hex, sha256Hex } from "./sha256.js";
import type {
  DownloadStreamOptions,
  PrepareChunkPlanOptions,
  PutChunkOptions,
} from "./types.js";
import { getChunkUrl, getStreamUrl, normalizeBaseUrl } from "./urls.js";

/** Default number of parallel HTTP `PUT /v1/chunks/{sha256}` workers during `uploadObject`. */
export const DEFAULT_UPLOAD_CONCURRENCY = 2;

const MAX_INT32 = 0x7fffffff;
const MAX_UINT64 = 0xffffffffffffffffn;

export interface LumaVaultClientOptions {
  baseUrl: string;
  transport?: Transport;
  fetch?: typeof globalThis.fetch;
  useBinaryFormat?: boolean;
  interceptors?: Interceptor[];
  defaultTimeoutMs?: number;
}

export type UploadPhase = "hashing" | "checking" | "uploading" | "committing";

export interface UploadProgress {
  phase: UploadPhase;
  /** Bytes hashed so far in the primary `data` payload. */
  hashedBytes: number;
  /** Total byte length of the primary `data` payload. */
  totalBytes: number;
  /** Count of unique missing chunks (including any missing thumbnail) uploaded so far. */
  uploadedChunks: number;
  /** Total unique missing chunks (including any missing thumbnail) scheduled for upload. */
  totalMissingChunks: number;
  /** Bytes uploaded so far across missing unique chunks (plus any missing thumbnail). */
  uploadedBytes: number;
  /** Total bytes across missing unique chunks (plus any missing thumbnail). */
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

export interface DownloadObjectOptions extends Omit<DownloadStreamOptions, "fetch"> {
  headers?: HeadersInit;
}

function assertValidObjectId(objectId: string): void {
  if (
    typeof objectId !== "string" ||
    objectId.trim().length === 0 ||
    objectId === "." ||
    objectId === ".." ||
    objectId.includes("/") ||
    objectId.includes("\\")
  ) {
    throw new RangeError(`Invalid objectId: "${String(objectId)}"`);
  }
}

function resolveTargetObjectId(target: string | { readonly id: string }): string {
  if (typeof target === "string") {
    assertValidObjectId(target);
    return target;
  }
  if (typeof target !== "object" || target === null) {
    throw new TypeError("target must be an objectId string or ObjectMetadata");
  }
  assertValidObjectId(target.id);
  return target.id;
}

function assertValidPageSize(pageSize: number): void {
  if (!Number.isSafeInteger(pageSize) || pageSize < 0 || pageSize > MAX_INT32) {
    throw new RangeError(
      `pageSize must be an integer between 0 and ${MAX_INT32}, got ${String(pageSize)}`,
    );
  }
}

/**
 * Builds the immutable content-addressed thumbnail URL (`{baseUrl}/v1/chunks/{thumbnailChunkHash}`),
 * or returns `null` when `thumbnailChunkHash` is empty or nullish.
 */
export function getThumbnailUrl(
  baseUrl: string,
  target: { readonly thumbnailChunkHash?: string | null } | string | null | undefined,
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
    if (options.fetch !== undefined) {
      this.fetchOverride = options.fetch;
    }
    let transport = options.transport;
    if (!transport) {
      const transportOpts: ConnectTransportOptions = { baseUrl: this.baseUrl };
      if (options.useBinaryFormat !== undefined) {
        transportOpts.useBinaryFormat = options.useBinaryFormat;
      }
      if (options.fetch !== undefined) {
        transportOpts.fetch = options.fetch;
      }
      if (options.interceptors !== undefined) {
        transportOpts.interceptors = options.interceptors;
      }
      if (options.defaultTimeoutMs !== undefined) {
        transportOpts.defaultTimeoutMs = options.defaultTimeoutMs;
      }
      transport = createConnectTransport(transportOpts);
    }
    this.rpc = createClient(StorageService, transport);
  }

  private resolveFetch(headers?: HeadersInit): typeof globalThis.fetch | undefined {
    if (headers === undefined) {
      return this.fetchOverride;
    }
    const baseFetch = this.fetchOverride;
    return (input, init) => {
      const merged = new Headers(headers);
      if (init?.headers) {
        new Headers(init.headers).forEach((value, key) => {
          merged.set(key, value);
        });
      }
      const nextInit: RequestInit = { ...init, headers: merged };
      return baseFetch ? baseFetch(input, nextInit) : globalThis.fetch(input, nextInit);
    };
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

    let thumbSize = 0;
    if (thumbnail !== undefined) {
      if (!(thumbnail instanceof Uint8Array) && !(thumbnail instanceof Blob)) {
        throw new TypeError("thumbnail must be a Blob or Uint8Array");
      }
      thumbSize =
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

    let hashedBytes = 0;
    let totalBytes = data instanceof Uint8Array ? data.byteLength : data instanceof Blob ? data.size : 0;
    let uploadedChunks = 0;
    let skippedChunks = 0;
    let uploadedBytes = 0;
    let totalUploadBytes = 0;
    const missingHashes: string[] = [];

    const emit = (phase: UploadPhase): void => {
      onProgress?.({
        phase,
        hashedBytes,
        totalBytes,
        uploadedChunks,
        totalMissingChunks: missingHashes.length,
        uploadedBytes,
        totalUploadBytes,
      });
    };

    const planOpts: PrepareChunkPlanOptions = {
      namespace,
      onProgress: (p) => {
        hashedBytes = p.hashedBytes;
        totalBytes = p.totalBytes;
        emit("hashing");
      },
    };
    if (chunkSizeBytes !== undefined) {
      planOpts.chunkSizeBytes = chunkSizeBytes;
    }
    if (signal !== undefined) {
      planOpts.signal = signal;
    }

    const plan = await prepareChunkPlan(data, planOpts);
    hashedBytes = plan.sizeBytes;
    totalBytes = plan.sizeBytes;

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
      uniqueChunks.set(thumbnailChunkHash, {
        sizeBytes: thumbSize,
        slice: () => thumbnail,
      });
    }

    const candidateHashes = Array.from(uniqueChunks.keys());
    const callOptions: CallOptions = {};
    if (signal !== undefined) {
      callOptions.signal = signal;
    }
    if (headers !== undefined) {
      callOptions.headers = headers;
    }

    if (candidateHashes.length > 0) {
      emit("checking");
      const hasRes = await this.hasChunks(candidateHashes, callOptions);
      signal?.throwIfAborted();

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
        emit("uploading");

        const poolController = new AbortController();
        const onCallerAbort = () => poolController.abort(signal?.reason);
        if (signal) {
          if (signal.aborted) {
            poolController.abort(signal.reason);
          } else {
            signal.addEventListener("abort", onCallerAbort, { once: true });
          }
        }

        const chunkFetch = this.resolveFetch(headers);
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
            const putOpts: PutChunkOptions = { signal: poolController.signal };
            if (chunkFetch !== undefined) {
              putOpts.fetch = chunkFetch;
            }
            try {
              await putChunk(this.baseUrl, hash, entry.slice(), putOpts);
              if (poolController.signal.aborted) {
                return;
              }
              uploadedChunks++;
              uploadedBytes += entry.sizeBytes;
              emit("uploading");
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

    signal?.throwIfAborted();
    emit("committing");

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
    assertValidSha256Hex(request.sha256Digest ?? "", "sha256Digest");
    if (request.thumbnailChunkHash !== undefined && request.thumbnailChunkHash !== "") {
      assertValidSha256Hex(request.thumbnailChunkHash, "thumbnailChunkHash");
    }
    const chunkHashes = request.chunkHashes ?? [];
    for (const hash of chunkHashes) {
      assertValidSha256Hex(hash, "chunkHash");
    }

    const sizeBytes = request.sizeBytes ?? 0n;
    if (typeof sizeBytes !== "bigint" || sizeBytes < 0n || sizeBytes > MAX_UINT64) {
      throw new RangeError(`Invalid sizeBytes: ${String(sizeBytes)}`);
    }
    const chunkSizeBytes = request.chunkSizeBytes ?? 0;
    if (
      !Number.isSafeInteger(chunkSizeBytes) ||
      chunkSizeBytes < 0 ||
      chunkSizeBytes > MAX_CHUNK_SIZE_BYTES
    ) {
      throw new RangeError(`Invalid chunkSizeBytes: ${String(chunkSizeBytes)}`);
    }
    if (sizeBytes === 0n) {
      if (chunkHashes.length !== 0) {
        throw new RangeError("chunkHashes must be empty when sizeBytes is 0");
      }
    } else {
      if (chunkSizeBytes === 0) {
        throw new RangeError("chunkSizeBytes must be > 0 when sizeBytes > 0");
      }
      const expectedChunks = 1n + (sizeBytes - 1n) / BigInt(chunkSizeBytes);
      if (BigInt(chunkHashes.length) !== expectedChunks) {
        throw new RangeError(
          `chunkHashes length (${chunkHashes.length}) does not match expected chunk count (${expectedChunks})`,
        );
      }
    }

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
    const reqInit: MessageInitShape<typeof ListObjectsRequestSchema> = {
      namespace: request.namespace,
    };
    if (request.pageSize !== undefined) {
      assertValidPageSize(request.pageSize);
      reqInit.pageSize = request.pageSize;
    }
    if (request.pageToken !== undefined) {
      reqInit.pageToken = request.pageToken;
    }
    return this.rpc.listObjects(reqInit, options);
  }

  /** Automatically follows `nextPageToken` cursors until all objects in `namespace` are yielded. */
  async *listAllObjects(
    namespace: Namespace,
    options: ListAllObjectsOptions = {},
  ): AsyncGenerator<ObjectMetadata, void, undefined> {
    defaultChunkSizeForNamespace(namespace);
    const { pageSize, ...callOptions } = options;
    if (pageSize !== undefined) {
      assertValidPageSize(pageSize);
    }
    let pageToken = "";
    const seenTokens = new Set<string>();

    while (true) {
      callOptions.signal?.throwIfAborted();
      const reqInit: MessageInitShape<typeof ListObjectsRequestSchema> = { namespace };
      if (pageSize !== undefined) {
        reqInit.pageSize = pageSize;
      }
      if (pageToken !== "") {
        reqInit.pageToken = pageToken;
      }
      const res = await this.rpc.listObjects(reqInit, callOptions);

      for (const obj of res.objects) {
        callOptions.signal?.throwIfAborted();
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

    const objectInit: MessageInitShape<typeof ObjectMetadataSchema> = { id: objectId };
    const paths: string[] = [];

    if (fields.filename !== undefined) {
      if (typeof fields.filename !== "string") {
        throw new TypeError("filename must be a string");
      }
      objectInit.filename = fields.filename;
      paths.push("filename");
    }
    if (fields.mimeType !== undefined) {
      if (typeof fields.mimeType !== "string") {
        throw new TypeError("mimeType must be a string");
      }
      objectInit.mimeType = fields.mimeType;
      paths.push("mime_type");
    }
    if (fields.thumbnailChunkHash !== undefined) {
      if (fields.thumbnailChunkHash !== "") {
        assertValidSha256Hex(fields.thumbnailChunkHash, "thumbnailChunkHash");
      }
      objectInit.thumbnailChunkHash = fields.thumbnailChunkHash;
      paths.push("thumbnail_chunk_hash");
    }

    if (paths.length === 0) {
      throw new RangeError(
        "updateObjectMetadata requires at least one mutable field (filename, mimeType, or thumbnailChunkHash)",
      );
    }

    const res = await this.rpc.updateObjectMetadata(
      {
        object: objectInit,
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
   * issuing an extra `GetObject` RPC (using `target.sha256Digest` when non-empty, or falling
   * back to strong `ETag` verification when an `objectId` or unpopulated `sha256Digest` is passed).
   */
  async downloadObject(
    target: string | { readonly id: string; readonly sha256Digest?: string | null },
    options: DownloadObjectOptions = {},
  ): Promise<Uint8Array> {
    const objectId = resolveTargetObjectId(target);
    const { headers, expectedSha256: optExpected, maxBytes, signal } = options;
    const expectedSha256 =
      optExpected !== undefined
        ? optExpected
        : typeof target === "string"
          ? undefined
          : (target.sha256Digest || undefined);

    const streamOpts: DownloadStreamOptions = {};
    const streamFetch = this.resolveFetch(headers);
    if (streamFetch !== undefined) {
      streamOpts.fetch = streamFetch;
    }
    if (expectedSha256 !== undefined) {
      streamOpts.expectedSha256 = expectedSha256;
    }
    if (maxBytes !== undefined) {
      streamOpts.maxBytes = maxBytes;
    }
    if (signal !== undefined) {
      streamOpts.signal = signal;
    }

    return downloadStream(this.baseUrl, objectId, streamOpts);
  }

  /** Builds the byte-range stream URL (`{baseUrl}/v1/stream/{objectId}`) for `<video>`/`<audio>`. */
  getStreamUrl(target: string | { readonly id: string }): string {
    const objectId = resolveTargetObjectId(target);
    return getStreamUrl(this.baseUrl, objectId);
  }

  /** Builds the content-addressed chunk URL (`{baseUrl}/v1/chunks/{sha256}`). */
  getChunkUrl(sha256: string): string {
    return getChunkUrl(this.baseUrl, sha256);
  }

  /** Builds the thumbnail URL (`{baseUrl}/v1/chunks/{thumbnailChunkHash}`), or `null` if unset. */
  getThumbnailUrl(
    target: { readonly thumbnailChunkHash?: string | null } | string | null | undefined,
  ): string | null {
    return getThumbnailUrl(this.baseUrl, target);
  }
}
