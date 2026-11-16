import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, it } from "node:test";

import { EMPTY_SHA256_DIGEST, SHA256_HEX_LENGTH } from "./constants.js";
import {
  Sha256,
  assertValidSha256Hex,
  isValidSha256Hex,
  sha256Hex,
} from "./sha256.js";

function nodeSha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function deterministicBytes(length: number, seed = 1): Uint8Array {
  const out = new Uint8Array(length);
  let state = seed >>> 0;
  for (let i = 0; i < length; i++) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    out[i] = (state >>> 24) & 0xff;
  }
  return out;
}

describe("SHA-256 hex validators and sha256Hex", () => {
  it("validates 64-character lowercase hex SHA-256 digests", () => {
    assert.equal(SHA256_HEX_LENGTH, 64);
    assert.equal(isValidSha256Hex(EMPTY_SHA256_DIGEST), true);
    assert.equal(isValidSha256Hex(EMPTY_SHA256_DIGEST.toUpperCase()), false);
    assert.equal(isValidSha256Hex(EMPTY_SHA256_DIGEST.slice(0, 63)), false);
    assert.equal(isValidSha256Hex(`${EMPTY_SHA256_DIGEST}0`), false);
    assert.equal(isValidSha256Hex("g".repeat(64)), false);
    assert.throws(() => assertValidSha256Hex("bad-hash"), RangeError);
  });

  it("hashes Blob and non-zero byteOffset Uint8Array inputs via Web Crypto", async () => {
    assert.equal(await sha256Hex(new Uint8Array(0)), EMPTY_SHA256_DIGEST);

    const backing = new Uint8Array(256).fill(0xee);
    const payload = deterministicBytes(73, 19);
    backing.set(payload, 41);

    const view = new Uint8Array(backing.buffer, 41, payload.byteLength);
    const expected = nodeSha256(payload);
    assert.equal(await sha256Hex(view), expected);
    assert.equal(await sha256Hex(new Blob([payload as Uint8Array<ArrayBuffer>])), expected);
  });

  it("falls back cleanly to pure-JS Sha256 when crypto.subtle is unavailable (plain-HTTP LAN)", async () => {
    const payload = deterministicBytes(200, 77);
    const expected = nodeSha256(payload);
    const originalCrypto = Object.getOwnPropertyDescriptor(globalThis, "crypto");

    Object.defineProperty(globalThis, "crypto", {
      value: { subtle: undefined },
      configurable: true,
    });
    try {
      assert.equal(await sha256Hex(payload), expected);
    } finally {
      if (originalCrypto) {
        Object.defineProperty(globalThis, "crypto", originalCrypto);
      }
    }
  });
});

describe("Sha256 incremental hasher", () => {
  it("matches NIST FIPS 180-4 test vectors and streaming block boundaries", () => {
    const enc = new TextEncoder();

    assert.equal(new Sha256().digestHex(), EMPTY_SHA256_DIGEST);
    assert.equal(
      new Sha256().update(enc.encode("abc")).digestHex(),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
    assert.equal(
      new Sha256()
        .update(enc.encode("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
        .digestHex(),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    );

    // Exercise 55, 56, 63, 64, 65, and 513-byte padding boundaries across irregular update sizes.
    for (const length of [1, 55, 56, 63, 64, 65, 128, 513, 4099]) {
      const payload = deterministicBytes(length, length);
      const expected = nodeSha256(payload);

      for (const step of [1, 7, 64, 131]) {
        const hasher = new Sha256();
        for (let offset = 0; offset < payload.byteLength; offset += step) {
          hasher.update(payload.subarray(offset, Math.min(offset + step, payload.byteLength)));
        }
        assert.equal(hasher.digestHex(), expected, `length=${length} step=${step}`);
        assert.equal(hasher.digestHex(), expected);
      }
    }
  });

  it("handles >= 512 MiB streams (totalBits >= 2^32) without 32-bit bit-length overflow", () => {
    const oneMiB = deterministicBytes(1024 * 1024, 513);
    const hasher = new Sha256();
    const ref = createHash("sha256");

    // 513 MiB equals 4,303,355,904 bits (above 2 to the 32), exercising the upper 32-bit length word.
    for (let i = 0; i < 513; i++) {
      hasher.update(oneMiB);
      ref.update(oneMiB);
    }

    assert.equal(hasher.digestHex(), ref.digest("hex"));
  });
});
