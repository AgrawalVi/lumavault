import { create } from "@bufbuild/protobuf";
import { FieldMaskSchema } from "@bufbuild/protobuf/wkt";
import { type Client, Code, ConnectError, createClient } from "@connectrpc/connect";
import { createConnectTransport } from "@connectrpc/connect-web";
import { gatewayChunkFetcher, verifiedStream } from "./download.js";
import { ObjectMetadataSchema, type ObjectMetadata, StorageService } from "./gen/lumavault/v1/storage_pb.js";
import type {
  DownloadOptions,
  ListOptions,
  ListPage,
  LumaVaultClientOptions,
  UpdateFields,
  UploadInput,
  UploadOptions,
  UploadResult,
} from "./types.js";
import { upload } from "./upload.js";
import { streamUrl } from "./urls.js";

// Maps update() keys to the proto field paths the gateway's FieldMask expects.
const UPDATE_MASK_PATHS: Record<keyof UpdateFields, string> = {
  filename: "filename",
  mimeType: "mime_type",
  thumbnailChunkHash: "thumbnail_chunk_hash",
};

/** One client per gateway. Create it once and use it for every storage call. */
export class LumaVaultClient {
  readonly #baseUrl: string;
  readonly #rpc: Client<typeof StorageService>;

  constructor(options: LumaVaultClientOptions) {
    this.#baseUrl = options.baseUrl;
    this.#rpc = createClient(
      StorageService,
      createConnectTransport({ baseUrl: options.baseUrl, useBinaryFormat: true }),
    );
  }

  /** Chunks, hashes, sends only missing chunks, and commits. Empty inputs are rejected. */
  async upload(input: UploadInput, options: UploadOptions): Promise<UploadResult> {
    const object = await upload(this.#rpc, this.#baseUrl, input, options);
    return { ...object, url: this.streamUrl(object.id) };
  }

  /** Streams the object's bytes, failing with data_loss if any chunk or the whole file mismatches. */
  download(id: string, options: DownloadOptions = {}): ReadableStream<Uint8Array> {
    return verifiedStream(this.get(id, options), gatewayChunkFetcher(this.#baseUrl), options.signal);
  }

  /** A URL for video players and other byte-range readers. Not hash-checked. */
  streamUrl(id: string): string {
    return streamUrl(this.#baseUrl, id);
  }

  async get(id: string, options: DownloadOptions = {}): Promise<ObjectMetadata> {
    const { object } = await this.#rpc.getObject({ objectId: id }, { signal: options.signal });
    if (!object) {
      throw new ConnectError(`gateway returned no object for ${id}`, Code.Internal);
    }
    return object;
  }

  /** Changes only the fields passed; the gateway's FieldMask is built from their keys. */
  async update(id: string, fields: UpdateFields): Promise<ObjectMetadata> {
    const keys = (Object.keys(fields) as (keyof UpdateFields)[]).filter((k) => fields[k] !== undefined);
    const { object } = await this.#rpc.updateObjectMetadata({
      object: create(ObjectMetadataSchema, { id, ...fields }),
      updateMask: create(FieldMaskSchema, { paths: keys.map((k) => UPDATE_MASK_PATHS[k]) }),
    });
    if (!object) {
      throw new ConnectError(`gateway returned no object for ${id}`, Code.Internal);
    }
    return object;
  }

  async delete(id: string): Promise<void> {
    await this.#rpc.deleteObject({ objectId: id });
  }

  /** One page of objects in a namespace. */
  async list(options: ListOptions): Promise<ListPage> {
    const res = await this.#rpc.listObjects({
      namespace: options.namespace,
      pageToken: options.cursor ?? "",
      pageSize: options.limit ?? 0,
    });
    const hasMore = res.nextPageToken !== "";
    return { objects: res.objects, cursor: hasMore ? res.nextPageToken : undefined, hasMore };
  }

  /** Every object in a namespace, fetching pages as the loop asks for them. */
  async *listAll(options: Omit<ListOptions, "cursor">): AsyncGenerator<ObjectMetadata> {
    let cursor: string | undefined;
    do {
      const page = await this.list({ ...options, cursor });
      yield* page.objects;
      cursor = page.cursor;
    } while (cursor);
  }
}
