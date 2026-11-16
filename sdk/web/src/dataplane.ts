import {
  DEFAULT_MAX_DOWNLOAD_BYTES,
  MAX_CHUNK_SIZE_BYTES,
} from "./constants.js";
import { LumaVaultDataPlaneError } from "./errors.js";
import { isValidSha256Hex, sha256Hex, toBufferSource } from "./sha256.js";
import type {
  DownloadStreamOptions,
  GetChunkOptions,
  PutChunkOptions,
  PutChunkResult,
} from "./types.js";
import {
  assertValidDataPlaneHash,
  getChunkUrl,
  getStreamUrl,
} from "./urls.js";

export { DEFAULT_MAX_DOWNLOAD_BYTES } from "./constants.js";
export { LumaVaultDataPlaneError } from "./errors.js";
export type {
  DataPlaneErrorCode,
  DataPlaneRequestOptions,
  DownloadStreamOptions,
  GetChunkOptions,
  LumaVaultDataPlaneErrorOptions,
  PutChunkOptions,
  PutChunkResult,
} from "./types.js";
export { getChunkUrl, getStreamUrl, normalizeBaseUrl } from "./urls.js";

async function readErrorText(response: Response): Promise<string> {
  try {
    const text = (await response.text()).trim();
    return text.length > 512 ? `${text.slice(0, 512)}...` : text;
  } catch {
    return "";
  }
}

async function toHttpError(response: Response, context: string): Promise<LumaVaultDataPlaneError> {
  const detail = await readErrorText(response);
  const suffix = detail ? `: ${detail}` : "";
  const status = response.status;

  if (status === 404) {
    return new LumaVaultDataPlaneError(
      "NOT_FOUND",
      `${context} not found (HTTP 404)${suffix}`,
      { status },
    );
  }
  if (status === 413) {
    return new LumaVaultDataPlaneError(
      "PAYLOAD_TOO_LARGE",
      `${context} exceeded maximum size (HTTP 413)${suffix}`,
      { status },
    );
  }
  if (status === 400 && /mismatch/i.test(detail)) {
    return new LumaVaultDataPlaneError(
      "HASH_MISMATCH",
      `${context} rejected due to SHA-256 mismatch (HTTP 400)${suffix}`,
      { status },
    );
  }
  return new LumaVaultDataPlaneError(
    "HTTP_ERROR",
    `${context} failed with HTTP ${status}${suffix}`,
    { status },
  );
}

function parseStrongEtagSha256(etagHeader: string | null): string | null {
  if (!etagHeader) {
    return null;
  }
  const trimmed = etagHeader.trim();
  if (trimmed.startsWith("W/") || trimmed.startsWith("w/")) {
    return null;
  }
  const unquoted =
    trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length >= 2
      ? trimmed.slice(1, -1)
      : trimmed;
  return isValidSha256Hex(unquoted) ? unquoted : null;
}

function parseContentLength(header: string | null): number | null {
  if (!header) {
    return null;
  }
  const trimmed = header.trim();
  if (!/^\d+$/.test(trimmed)) {
    return null;
  }
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

async function cancelBodyQuietly(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // Ignore cancellation errors on error paths.
  }
}

async function readResponseBytes(
  response: Response,
  maxBytes: number,
  signal?: AbortSignal,
): Promise<Uint8Array> {
  signal?.throwIfAborted();

  const declaredLength = parseContentLength(response.headers.get("Content-Length"));
  if (declaredLength !== null && declaredLength > maxBytes) {
    await cancelBodyQuietly(response);
    throw new LumaVaultDataPlaneError(
      "PAYLOAD_TOO_LARGE",
      `Response Content-Length (${declaredLength} bytes) exceeds maxBytes (${maxBytes} bytes)`,
      { status: response.status },
    );
  }

  if (!response.body) {
    return new Uint8Array(0);
  }

  const reader = response.body.getReader();
  let cancelPromise: Promise<unknown> | null = null;
  const onAbort = () => {
    cancelPromise = reader.cancel(signal?.reason).catch(() => {});
  };
  signal?.addEventListener("abort", onAbort, { once: true });

  const chunks: Uint8Array[] = [];
  let totalBytes = 0;

  try {
    while (true) {
      signal?.throwIfAborted();
      const { done, value } = await reader.read();
      if (cancelPromise) {
        await cancelPromise;
      }
      signal?.throwIfAborted();
      if (done) {
        break;
      }
      if (value.byteLength === 0) {
        continue;
      }
      totalBytes += value.byteLength;
      if (totalBytes > maxBytes) {
        await reader.cancel().catch(() => {});
        throw new LumaVaultDataPlaneError(
          "PAYLOAD_TOO_LARGE",
          `Stream exceeded maxBytes limit (${maxBytes} bytes)`,
          { status: response.status },
        );
      }
      chunks.push(value);
    }
  } finally {
    signal?.removeEventListener("abort", onAbort);
    if (cancelPromise) {
      await cancelPromise;
    }
    reader.releaseLock();
  }

  if (chunks.length === 0) {
    return new Uint8Array(0);
  }
  if (chunks.length === 1) {
    return chunks[0]!;
  }

  const out = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/**
 * Uploads a single chunk (`Blob` or `Uint8Array`) via `PUT /v1/chunks/{sha256}`, validating
 * `{sha256}` and `MAX_CHUNK_SIZE_BYTES` locally before sending bytes over the wire.
 */
export async function putChunk(
  baseUrl: string,
  sha256: string,
  data: Blob | Uint8Array,
  options: PutChunkOptions = {},
): Promise<PutChunkResult> {
  const url = getChunkUrl(baseUrl, sha256);
  const { signal, fetch: fetchFn = globalThis.fetch, verifyLocalHash = false } = options;
  signal?.throwIfAborted();

  if (!(data instanceof Uint8Array) && !(data instanceof Blob)) {
    throw new TypeError("data must be a Blob or Uint8Array");
  }

  const sizeBytes = data instanceof Uint8Array ? data.byteLength : data.size;
  if (sizeBytes > MAX_CHUNK_SIZE_BYTES) {
    throw new LumaVaultDataPlaneError(
      "PAYLOAD_TOO_LARGE",
      `Chunk payload (${sizeBytes} bytes) exceeds maximum chunk size (${MAX_CHUNK_SIZE_BYTES} bytes)`,
    );
  }

  if (verifyLocalHash) {
    const localHash = await sha256Hex(data, signal);
    if (localHash !== sha256) {
      throw new LumaVaultDataPlaneError(
        "HASH_MISMATCH",
        `Local chunk SHA-256 mismatch: expected ${sha256}, got ${localHash}`,
      );
    }
  }

  const body: BodyInit = data instanceof Uint8Array ? toBufferSource(data) : data;
  const response = await fetchFn(url, {
    method: "PUT",
    headers: { "Content-Type": "application/octet-stream" },
    body,
    signal,
  });

  if (!response.ok) {
    throw await toHttpError(response, `PUT /v1/chunks/${sha256}`);
  }

  const rawBody = (await response.text()).trim();
  if (rawBody.length > 0) {
    let parsed: { sha256?: unknown; size_bytes?: unknown } | null = null;
    try {
      parsed = JSON.parse(rawBody) as { sha256?: unknown; size_bytes?: unknown };
    } catch {
      parsed = null;
    }
    if (parsed && typeof parsed.sha256 === "string" && parsed.sha256 !== sha256) {
      throw new LumaVaultDataPlaneError(
        "HASH_MISMATCH",
        `Server returned mismatched SHA-256: expected ${sha256}, got ${parsed.sha256}`,
        { status: response.status },
      );
    }
    if (parsed && typeof parsed.size_bytes === "number" && Number.isSafeInteger(parsed.size_bytes)) {
      return { sha256, sizeBytes: parsed.size_bytes };
    }
  }

  return { sha256, sizeBytes };
}

/**
 * Downloads a single chunk via `GET /v1/chunks/{sha256}` and verifies its `SHA-256` digest
 * against `{sha256}` by default before returning the bytes.
 */
export async function getChunk(
  baseUrl: string,
  sha256: string,
  options: GetChunkOptions = {},
): Promise<Uint8Array> {
  const url = getChunkUrl(baseUrl, sha256);
  const { signal, fetch: fetchFn = globalThis.fetch, verify = true } = options;
  signal?.throwIfAborted();

  const response = await fetchFn(url, {
    method: "GET",
    signal,
  });

  if (!response.ok) {
    throw await toHttpError(response, `GET /v1/chunks/${sha256}`);
  }

  const bytes = await readResponseBytes(response, MAX_CHUNK_SIZE_BYTES, signal);
  if (verify) {
    const actualHash = await sha256Hex(bytes, signal);
    if (actualHash !== sha256) {
      throw new LumaVaultDataPlaneError(
        "HASH_MISMATCH",
        `Chunk SHA-256 mismatch for ${sha256}: got ${actualHash}`,
        { status: response.status },
      );
    }
  }

  return bytes;
}

/**
 * Downloads a full object stream via `GET /v1/stream/{objectId}` into memory with a streaming
 * `maxBytes` cap (default `256 MiB`) and verifies its `SHA-256` digest against `expectedSha256`
 * or a quote-stripped strong `ETag` response header.
 */
export async function downloadStream(
  baseUrl: string,
  objectId: string,
  options: DownloadStreamOptions = {},
): Promise<Uint8Array> {
  const url = getStreamUrl(baseUrl, objectId);
  const {
    signal,
    fetch: fetchFn = globalThis.fetch,
    expectedSha256,
    maxBytes = DEFAULT_MAX_DOWNLOAD_BYTES,
  } = options;

  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new RangeError(`maxBytes must be a non-negative safe integer, got ${String(maxBytes)}`);
  }
  if (expectedSha256 !== undefined) {
    assertValidDataPlaneHash(expectedSha256, "expectedSha256");
  }
  signal?.throwIfAborted();

  const response = await fetchFn(url, {
    method: "GET",
    signal,
  });

  if (!response.ok) {
    throw await toHttpError(response, `GET /v1/stream/${encodeURIComponent(objectId)}`);
  }
  if (response.status !== 200) {
    await cancelBodyQuietly(response);
    throw new LumaVaultDataPlaneError(
      "HTTP_ERROR",
      `Expected HTTP 200 OK for full stream download, got HTTP ${response.status}`,
      { status: response.status },
    );
  }

  const targetSha256 =
    expectedSha256 ?? parseStrongEtagSha256(response.headers.get("ETag"));
  if (!targetSha256) {
    await cancelBodyQuietly(response);
    throw new LumaVaultDataPlaneError(
      "INVALID_HASH",
      `Cannot verify stream "${objectId}": missing expectedSha256 and response lacks a valid strong SHA-256 ETag`,
      { status: response.status },
    );
  }

  const bytes = await readResponseBytes(response, maxBytes, signal);
  const actualSha256 = await sha256Hex(bytes, signal);
  if (actualSha256 !== targetSha256) {
    throw new LumaVaultDataPlaneError(
      "HASH_MISMATCH",
      `Stream SHA-256 mismatch for "${objectId}": expected ${targetSha256}, got ${actualSha256}`,
      { status: response.status },
    );
  }

  return bytes;
}
