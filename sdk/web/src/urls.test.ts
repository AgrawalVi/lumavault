import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { EMPTY_SHA256_DIGEST } from "./constants.js";
import { LumaVaultDataPlaneError } from "./errors.js";
import { getChunkUrl, getStreamUrl, normalizeBaseUrl } from "./urls.js";

describe("URL builders", () => {
  it("normalizes trailing slashes on baseUrl, preserves '/', and encodes objectId", () => {
    assert.equal(normalizeBaseUrl("http://localhost:8080///"), "http://localhost:8080");
    assert.equal(normalizeBaseUrl("/"), "/");
    assert.equal(normalizeBaseUrl(normalizeBaseUrl("/")), "/");
    assert.equal(normalizeBaseUrl("/api/storage///"), "/api/storage");

    assert.equal(
      getChunkUrl("http://localhost:8080///", EMPTY_SHA256_DIGEST),
      `http://localhost:8080/v1/chunks/${EMPTY_SHA256_DIGEST}`,
    );
    assert.equal(
      getChunkUrl("/", EMPTY_SHA256_DIGEST),
      `/v1/chunks/${EMPTY_SHA256_DIGEST}`,
    );
    assert.equal(
      getStreamUrl("http://localhost:8080/", "movie/4k hdr #1?.mkv"),
      "http://localhost:8080/v1/stream/movie%2F4k%20hdr%20%231%3F.mkv",
    );
    assert.equal(getStreamUrl("/", "obj-root"), "/v1/stream/obj-root");

    assert.throws(
      () => getChunkUrl("http://localhost:8080", "NOT_HEX"),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError && err.code === "INVALID_HASH",
    );
    assert.throws(() => normalizeBaseUrl("   "), TypeError);
    assert.throws(() => normalizeBaseUrl("///"), RangeError);
    assert.throws(() => normalizeBaseUrl("//evil.example"), RangeError);
    assert.throws(() => normalizeBaseUrl("http://localhost:8080?foo=1"), RangeError);
    assert.throws(() => normalizeBaseUrl("http://localhost:8080#hash"), RangeError);
    assert.throws(() => getStreamUrl("http://localhost:8080", ""), RangeError);
    assert.throws(() => getStreamUrl("http://localhost:8080", "   "), RangeError);
    assert.throws(() => getStreamUrl("http://localhost:8080", "."), RangeError);
    assert.throws(() => getStreamUrl("http://localhost:8080", ".."), RangeError);
    assert.throws(() => getStreamUrl("http://localhost:8080", "/"), RangeError);
  });
});
