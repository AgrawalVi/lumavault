export {
  Code,
  ConnectError,
  type CallOptions,
  type Transport,
} from "@connectrpc/connect";

export * from "./gen/lumavault/v1/storage_pb.js";
export * from "./constants.js";
export * from "./errors.js";
export type * from "./types.js";
export {
  Sha256,
  assertValidSha256Hex,
  bytesToHex,
  isValidSha256Hex,
  sha256Hex,
  toBufferSource,
} from "./sha256.js";
export {
  assertValidDataPlaneHash,
  getChunkUrl,
  getStreamUrl,
  normalizeBaseUrl,
} from "./urls.js";
export {
  assertValidChunkSize,
  defaultChunkSizeForNamespace,
  isValidChunkSize,
  prepareChunkPlan,
} from "./chunker.js";
export { downloadStream, getChunk, putChunk } from "./dataplane.js";
export {
  DEFAULT_UPLOAD_CONCURRENCY,
  LumaVaultClient,
  getThumbnailUrl,
  type DownloadObjectOptions,
  type ListAllObjectsOptions,
  type ListObjectsOptions,
  type LumaVaultClientOptions,
  type UpdateObjectMetadataFields,
  type UploadObjectOptions,
  type UploadObjectResult,
  type UploadPhase,
  type UploadProgress,
} from "./client.js";
