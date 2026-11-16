import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { EMPTY_SHA256_DIGEST } from "./constants.js";
import { LumaVaultDataPlaneError } from "./errors.js";
import { getChunkUrl, getStreamUrl, normalizeBaseUrl } from "./urls.js";

describe("URL builders", () => {
  it("normalizes trailing slashes on baseUrl and encodes objectId", () => {
    assert.equal(normalizeBaseUrl("http://localhost:8080///"), "http://localhost:8080");
    assert.equal(
      getChunkUrl("http://localhost:8080///", EMPTY_SHA256_DIGEST),
      `http://localhost:8080/v1/chunks/${EMPTY_SHA256_DIGEST}`,
    );
    assert.equal(
      getStreamUrl("http://localhost:8080/", "movie/4k hdr #1?.mkv"),
      "http://localhost:8080/v1/stream/movie%2F4k%20hdr%20%231%3F.mkv",
    );

    assert.throws(
      () => getChunkUrl("http://localhost:8080", "NOT_HEX"),
      (err: unknown) =>
        err instanceof LumaVaultDataPlaneError && err.code === "INVALID_HASH",
    );
    assert.throws(() => getStreamUrl("http://localhost:8080", ""), RangeError);
    assert.throws(() => getStreamUrl("http://localhost:8080", ".."), RangeError);
    assert.throws(() => getStreamUrl("   ", "obj-1"), TypeError);
  });
});
