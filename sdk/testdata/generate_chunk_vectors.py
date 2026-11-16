#!/usr/bin/env python3
# Regenerates chunk-vectors.json with an implementation independent of both SDKs.
# Run from the repo root: python3 sdk/testdata/generate_chunk_vectors.py
import hashlib
import json
import os

MIB = 1024 * 1024
GIB = 1024 * MIB
MIN_CHUNK = 4 * MIB
MAX_CHUNK = 64 * MIB
TARGET_MAX_CHUNKS = 256
PATTERN_MODULUS = 251


def chunk_size_for(size):
    chunk = MIN_CHUNK
    while chunk < MAX_CHUNK and chunk * TARGET_MAX_CHUNKS < size:
        chunk *= 2
    return chunk


def pattern(size):
    block = bytes(range(PATTERN_MODULUS))
    data = block * (size // PATTERN_MODULUS + 1)
    return data[:size]


def file_vector(name, size):
    data = pattern(size)
    chunk = chunk_size_for(size)
    hashes = [hashlib.sha256(data[i:i + chunk]).hexdigest() for i in range(0, size, chunk)]
    return {
        "name": name,
        "sizeBytes": size,
        "chunkSizeBytes": chunk,
        "sha256": hashlib.sha256(data).hexdigest(),
        "chunkHashes": hashes,
    }


def main():
    sizes = [1, GIB, GIB + 1, 2 * GIB, 2 * GIB + 1, 4 * GIB, 4 * GIB + 1, 8 * GIB, 8 * GIB + 1, 100 * GIB]
    vectors = {
        "pattern": "Byte at offset i has value i mod 251.",
        "chunkSizeRule": [{"sizeBytes": s, "chunkSizeBytes": chunk_size_for(s)} for s in sizes],
        "files": [
            file_vector("one byte", 1),
            file_vector("smaller than one chunk", 1000),
            file_vector("exactly one chunk", MIN_CHUNK),
            file_vector("one chunk plus one byte", MIN_CHUNK + 1),
            file_vector("exactly two chunks", 2 * MIN_CHUNK),
            file_vector("three chunks minus one byte", 3 * MIN_CHUNK - 1),
        ],
    }
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "chunk-vectors.json")
    with open(out, "w") as f:
        json.dump(vectors, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
