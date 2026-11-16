import { LumaVaultDataPlaneError } from "./errors.js";
import { isValidSha256Hex } from "./sha256.js";

/** Trims and strips trailing slashes from a Gateway `baseUrl`. */
export function normalizeBaseUrl(baseUrl: string): string {
  if (typeof baseUrl !== "string" || baseUrl.trim().length === 0) {
    throw new TypeError("baseUrl must be a non-empty string");
  }
  return baseUrl.trim().replace(/\/+$/, "");
}

/** Throws `LumaVaultDataPlaneError("INVALID_HASH")` if `sha256` is not 64-char lowercase hex. */
export function assertValidDataPlaneHash(sha256: string, label = "sha256"): void {
  if (!isValidSha256Hex(sha256)) {
    throw new LumaVaultDataPlaneError(
      "INVALID_HASH",
      `Invalid ${label}: expected 64-character lowercase hex SHA-256 digest, got "${String(sha256)}"`,
    );
  }
}

/**
 * Builds the content-addressed chunk URL (`{baseUrl}/v1/chunks/{sha256}`), suitable for
 * raw chunk `PUT`/`GET` requests and immutable cached `<img>` thumbnails.
 */
export function getChunkUrl(baseUrl: string, sha256: string): string {
  const root = normalizeBaseUrl(baseUrl);
  assertValidDataPlaneHash(sha256, "chunk sha256");
  return `${root}/v1/chunks/${sha256}`;
}

/**
 * Builds the byte-range media stream URL (`{baseUrl}/v1/stream/{objectId}`), suitable for
 * HTML5 `<video>` / `<audio>` `HTTP 206 Partial Content` playback and full-object downloads.
 */
export function getStreamUrl(baseUrl: string, objectId: string): string {
  const root = normalizeBaseUrl(baseUrl);
  if (
    typeof objectId !== "string" ||
    objectId.length === 0 ||
    objectId === "." ||
    objectId === ".."
  ) {
    throw new RangeError(`Invalid objectId: "${String(objectId)}"`);
  }
  return `${root}/v1/stream/${encodeURIComponent(objectId)}`;
}
