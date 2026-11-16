import { EMPTY_SHA256_DIGEST, SHA256_HEX_LENGTH } from "./constants.js";

const SHA256_HEX_REGEX = /^[0-9a-f]{64}$/;

const HEX_TABLE: readonly string[] = Array.from({ length: 256 }, (_, i) =>
  i.toString(16).padStart(2, "0"),
);

const SHA256_INITIAL_STATE = new Uint32Array([
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
]);

const SHA256_K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

/** Returns true if hash is a canonical 64-character lowercase hexadecimal SHA-256 string. */
export function isValidSha256Hex(hash: string): boolean {
  return (
    typeof hash === "string" &&
    hash.length === SHA256_HEX_LENGTH &&
    SHA256_HEX_REGEX.test(hash)
  );
}

/** Throws a RangeError if hash is not a canonical 64-character lowercase hex SHA-256 digest. */
export function assertValidSha256Hex(hash: string, label = "sha256"): void {
  if (!isValidSha256Hex(hash)) {
    throw new RangeError(
      `${label} must be a 64-character lowercase hexadecimal SHA-256 digest, got "${String(hash)}"`,
    );
  }
}

/**
 * Adapts a Uint8Array view to a Web Crypto or Fetch BufferSource preserving exact byteOffset
 * and byteLength (zero-copy for ArrayBuffer; copies only the slice if SharedArrayBuffer).
 */
export function toBufferSource(view: Uint8Array): BufferSource {
  if (view.buffer instanceof ArrayBuffer) {
    return new DataView(view.buffer, view.byteOffset, view.byteLength);
  }
  const copy = new Uint8Array(view.byteLength);
  copy.set(view);
  return copy;
}

function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    out += HEX_TABLE[bytes[i]!];
  }
  return out;
}

/**
 * Computes the lowercase hex SHA-256 digest of a single Blob or Uint8Array.
 * Uses hardware-accelerated Web Crypto when available, falling back to Sha256 on plain-HTTP LAN origins.
 */
export async function sha256Hex(
  data: Blob | Uint8Array,
  signal?: AbortSignal,
): Promise<string> {
  signal?.throwIfAborted();
  const size = data instanceof Uint8Array ? data.byteLength : data.size;
  if (size === 0) {
    return EMPTY_SHA256_DIGEST;
  }
  const bytes =
    data instanceof Uint8Array
      ? data
      : new Uint8Array(await data.arrayBuffer());
  signal?.throwIfAborted();

  const subtle = globalThis.crypto?.subtle;
  if (subtle) {
    const digest = await subtle.digest("SHA-256", toBufferSource(bytes));
    signal?.throwIfAborted();
    return bytesToHex(new Uint8Array(digest));
  }

  return new Sha256().update(bytes).digestHex();
}

/**
 * Minimal, dependency-free incremental FIPS 180-4 SHA-256 hasher used to compute whole-file
 * digests across multi-chunk streams while keeping memory bounded to a single chunk slice.
 */
export class Sha256 {
  private readonly state = new Uint32Array(SHA256_INITIAL_STATE);
  private readonly block = new Uint8Array(64);
  private readonly blockView = new DataView(this.block.buffer);
  private readonly schedule = new Uint32Array(64);
  private blockLen = 0;
  private totalBytes = 0;

  update(data: Uint8Array): this {
    let offset = 0;
    const len = data.byteLength;
    if (len === 0) {
      return this;
    }
    this.totalBytes += len;

    if (this.blockLen > 0) {
      const needed = 64 - this.blockLen;
      if (len < needed) {
        this.block.set(data, this.blockLen);
        this.blockLen += len;
        return this;
      }
      this.block.set(data.subarray(0, needed), this.blockLen);
      this.compress(this.blockView, 0);
      this.blockLen = 0;
      offset = needed;
    }

    if (offset + 64 <= len) {
      const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
      while (offset + 64 <= len) {
        this.compress(view, offset);
        offset += 64;
      }
    }

    if (offset < len) {
      const remaining = len - offset;
      this.block.set(data.subarray(offset, len), 0);
      this.blockLen = remaining;
    }

    return this;
  }

  digestHex(): string {
    const savedState = new Uint32Array(this.state);
    const padBlock = new Uint8Array(this.block);
    const padView = new DataView(padBlock.buffer);
    let padLen = this.blockLen;

    padBlock[padLen++] = 0x80;
    if (padLen > 56) {
      padBlock.fill(0, padLen, 64);
      this.compress(padView, 0);
      padLen = 0;
    }
    padBlock.fill(0, padLen, 56);

    // Use BigInt bit count so files of 512 MiB or larger (such as 50 GB+ 4K videos) never overflow 32-bit shifts.
    const totalBits = BigInt(this.totalBytes) * 8n;
    padView.setUint32(56, Number((totalBits >> 32n) & 0xffffffffn), false);
    padView.setUint32(60, Number(totalBits & 0xffffffffn), false);
    this.compress(padView, 0);

    let hex = "";
    for (let i = 0; i < 8; i++) {
      hex += this.state[i]!.toString(16).padStart(8, "0");
    }

    this.state.set(savedState);
    return hex;
  }

  private compress(view: DataView, offset: number): void {
    const w = this.schedule;
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(offset + i * 4, false);
    }
    for (let i = 16; i < 64; i++) {
      const w15 = w[i - 15]!;
      const s0 = ((w15 >>> 7) | (w15 << 25)) ^ ((w15 >>> 18) | (w15 << 14)) ^ (w15 >>> 3);
      const w2 = w[i - 2]!;
      const s1 = ((w2 >>> 17) | (w2 << 15)) ^ ((w2 >>> 19) | (w2 << 13)) ^ (w2 >>> 10);
      w[i] = (w[i - 16]! + s0 + w[i - 7]! + s1) >>> 0;
    }

    let a = this.state[0]!;
    let b = this.state[1]!;
    let c = this.state[2]!;
    let d = this.state[3]!;
    let e = this.state[4]!;
    let f = this.state[5]!;
    let g = this.state[6]!;
    let h = this.state[7]!;

    for (let i = 0; i < 64; i++) {
      const s1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + s1 + ch + SHA256_K[i]! + w[i]!) >>> 0;
      const s0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + maj) >>> 0;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) >>> 0;
    }

    this.state[0] = (this.state[0]! + a) >>> 0;
    this.state[1] = (this.state[1]! + b) >>> 0;
    this.state[2] = (this.state[2]! + c) >>> 0;
    this.state[3] = (this.state[3]! + d) >>> 0;
    this.state[4] = (this.state[4]! + e) >>> 0;
    this.state[5] = (this.state[5]! + f) >>> 0;
    this.state[6] = (this.state[6]! + g) >>> 0;
    this.state[7] = (this.state[7]! + h) >>> 0;
  }
}
