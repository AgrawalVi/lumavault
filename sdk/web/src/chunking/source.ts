/** Anything the SDK can upload. A File is a Blob, so it is covered too. */
export type UploadInput = Blob | Uint8Array;

/** Random-access reader over an upload input that only materializes the requested range. */
export interface ByteSource {
  readonly size: number;
  read(start: number, end: number): Promise<Uint8Array<ArrayBuffer>>;
}

export function toByteSource(input: UploadInput): ByteSource {
  if (input instanceof Uint8Array) {
    return {
      size: input.byteLength,
      read: async (start, end) => {
        const view = input.subarray(start, end);
        // Web Crypto rejects views over SharedArrayBuffer, so copy only in that rare case.
        return view.buffer instanceof ArrayBuffer ? (view as Uint8Array<ArrayBuffer>) : new Uint8Array(view);
      },
    };
  }
  return {
    size: input.size,
    read: async (start, end) => new Uint8Array(await input.slice(start, end).arrayBuffer()),
  };
}
