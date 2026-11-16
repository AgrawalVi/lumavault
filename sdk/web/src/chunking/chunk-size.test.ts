import { describe, expect, it } from "vitest";
import { loadVectors } from "../testutil/vectors.js";
import { chunkSizeFor } from "./chunk-size.js";

describe("chunkSizeFor", () => {
  for (const { sizeBytes, chunkSizeBytes } of loadVectors().chunkSizeRule) {
    it(`picks ${chunkSizeBytes} bytes for a ${sizeBytes}-byte file`, () => {
      expect(chunkSizeFor(sizeBytes)).toBe(chunkSizeBytes);
    });
  }
});
