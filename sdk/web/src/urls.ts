import { CHUNKS_PATH, STREAM_PATH } from "./constants.js";

/** Joins a base URL and a relative path whether or not the base ends with a slash. */
export function joinUrl(baseUrl: string, path: string): string {
  return baseUrl.endsWith("/") ? baseUrl + path : `${baseUrl}/${path}`;
}

export function chunkUrl(baseUrl: string, sha256: string): string {
  return joinUrl(baseUrl, CHUNKS_PATH + sha256);
}

export function streamUrl(baseUrl: string, objectId: string): string {
  return joinUrl(baseUrl, STREAM_PATH + encodeURIComponent(objectId));
}
