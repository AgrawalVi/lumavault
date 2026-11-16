import { LumaVaultDataPlaneError } from "./errors.js";
import { isValidSha256Hex } from "./sha256.js";

/**
 * Trims and normalizes a Gateway baseUrl, preserving "/" for same-origin root deployments
 * so repeated calls are idempotent.
 */
export function normalizeBaseUrl(baseUrl: string): string {
  if (typeof baseUrl !== "string" || baseUrl.trim().length === 0) {
    throw new TypeError("baseUrl must be a non-empty string");
  }
  const trimmed = baseUrl.trim();
  if (/[?#]/.test(trimmed) || trimmed.startsWith("//")) {
    throw new RangeError(`Invalid baseUrl: "${baseUrl}"`);
  }
  if (trimmed === "/") {
    return "/";
  }
  return trimmed.replace(/\/+$/, "");
}

function baseUrlPrefix(baseUrl: string): string {
  const root = normalizeBaseUrl(baseUrl);
  return root === "/" ? "" : root;
}

/** Throws LumaVaultDataPlaneError when sha256 is not a 64-character lowercase hex string. */
export function assertValidDataPlaneHash(sha256: string, label = "sha256"): void {
  if (!isValidSha256Hex(sha256)) {
    throw new LumaVaultDataPlaneError(
      "INVALID_HASH",
      `Invalid ${label}: expected 64-character lowercase hex SHA-256 digest, got "${String(sha256)}"`,
    );
  }
}

/**
 * Builds the content-addressed chunk URL ({baseUrl}/v1/chunks/{sha256}) for raw chunk
 * PUT and GET requests and immutable cached thumbnails.
 */
export function getChunkUrl(baseUrl: string, sha256: string): string {
  const prefix = baseUrlPrefix(baseUrl);
  assertValidDataPlaneHash(sha256, "chunk sha256");
  return `${prefix}/v1/chunks/${sha256}`;
}

/**
 * Builds the byte-range media stream URL ({baseUrl}/v1/stream/{objectId}) for HTTP 206
 * Partial Content playback and full-object downloads.
 */
export function getStreamUrl(baseUrl: string, objectId: string): string {
  const prefix = baseUrlPrefix(baseUrl);
  if (
    typeof objectId !== "string" ||
    objectId.trim().length === 0 ||
    objectId === "." ||
    objectId === ".." ||
    objectId === "/"
  ) {
    throw new RangeError(`Invalid objectId: "${String(objectId)}"`);
  }
  return `${prefix}/v1/stream/${encodeURIComponent(objectId)}`;
}
