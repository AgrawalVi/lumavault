export { create, type MessageInitShape } from "@bufbuild/protobuf";
export {
  timestampDate,
  timestampFromDate,
  timestampFromMs,
  timestampMs,
  timestampNow,
  type FieldMask,
  type Timestamp,
} from "@bufbuild/protobuf/wkt";
export {
  Code,
  ConnectError,
  createClient,
  type CallOptions,
  type Client,
  type Interceptor,
  type Transport,
} from "@connectrpc/connect";
export {
  createConnectTransport,
  createGrpcWebTransport,
  type ConnectTransportOptions,
  type GrpcWebTransportOptions,
} from "@connectrpc/connect-web";

export * from "./gen/lumavault/v1/storage_pb.js";
export * from "./constants.js";
export * from "./errors.js";
export type * from "./types.js";
export {
  Sha256,
  assertValidSha256Hex,
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
