import Connect
import CryptoKit
import Foundation
import XCTest
@testable import LumaVaultSDK

final class ChunkerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumavault-chunker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testDefaultChunkSizeForNamespace() throws {
        XCTAssertEqual(try Chunker.defaultChunkSize(for: .photos), 4 * 1024 * 1024)
        XCTAssertEqual(try Chunker.defaultChunkSize(for: .games), 4 * 1024 * 1024)
        XCTAssertEqual(try Chunker.defaultChunkSize(for: .cinema), 64 * 1024 * 1024)

        XCTAssertThrowsError(try Chunker.defaultChunkSize(for: .unspecified)) { error in
            XCTAssertEqual(error as? LumaVaultError, .invalidNamespace(.unspecified))
        }
        XCTAssertThrowsError(try Chunker.defaultChunkSize(for: .UNRECOGNIZED(99))) { error in
            XCTAssertEqual(error as? LumaVaultError, .invalidNamespace(.UNRECOGNIZED(99)))
        }
    }

    func testValidatorsAndErrorDescriptions() throws {
        let validHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        XCTAssertNoThrow(try Chunker.validateHash(validHash))

        for badHash in [
            "",
            "e3b0c442",
            validHash.uppercased(),
            String(repeating: "g", count: 64),
        ] {
            XCTAssertThrowsError(try Chunker.validateHash(badHash)) { error in
                XCTAssertEqual(error as? LumaVaultError, .invalidHash(badHash))
            }
        }

        XCTAssertThrowsError(try Chunker.validateChunkSize(Chunker.minChunkSizeBytes - 1)) { error in
            XCTAssertEqual(error as? LumaVaultError, .invalidChunkSize(Chunker.minChunkSizeBytes - 1))
        }
        XCTAssertThrowsError(try Chunker.validateChunkSize(Chunker.maxChunkSizeBytes + 1)) { error in
            XCTAssertEqual(error as? LumaVaultError, .invalidChunkSize(Chunker.maxChunkSizeBytes + 1))
        }

        let rpcErr = LumaVaultError.rpcError(code: .notFound, message: "object missing")
        XCTAssertEqual(rpcErr, LumaVaultError.rpcError(code: .notFound, message: "object missing"))
        XCTAssertNotNil(rpcErr.errorDescription)
    }

    func testZeroBytePlanMatchesEmptySHA256Vector() throws {
        let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let fileURL = tempDirectory.appendingPathComponent("empty.bin")
        try Data().write(to: fileURL)

        var fileProgressCalls: [(UInt64, UInt64)] = []
        let filePlan = try Chunker.planFile(at: fileURL) { hashed, total in
            fileProgressCalls.append((hashed, total))
        }
        let dataPlan = try Chunker.planData(Data())

        XCTAssertEqual(filePlan, dataPlan)
        XCTAssertEqual(filePlan.sizeBytes, 0)
        XCTAssertEqual(filePlan.sha256Digest, emptySHA256)
        XCTAssertTrue(filePlan.chunks.isEmpty)
        XCTAssertEqual(fileProgressCalls.count, 1)
        XCTAssertEqual(fileProgressCalls.first?.0, 0)
        XCTAssertEqual(try Chunker.readChunk(from: fileURL, offset: 0, length: 0), Data())
    }

    func testSingleChunkPlanMatchesKnownVectorAndReadChunk() throws {
        let abc = Data("abc".utf8)
        let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let fileURL = tempDirectory.appendingPathComponent("abc.bin")
        try abc.write(to: fileURL)

        let filePlan = try Chunker.planFile(at: fileURL)
        let dataPlan = try Chunker.planData(abc)

        XCTAssertEqual(filePlan, dataPlan)
        XCTAssertEqual(filePlan.sizeBytes, 3)
        XCTAssertEqual(filePlan.sha256Digest, abcSHA256)
        XCTAssertEqual(
            filePlan.chunks,
            [ChunkDescriptor(index: 0, hash: abcSHA256, offset: 0, length: 3)]
        )
        XCTAssertEqual(try Chunker.readChunk(from: fileURL, chunk: filePlan.chunks[0]), abc)
    }

    func testExactFourMiBBoundaryProducesSingleChunk() throws {
        let exactFourMiB = makeDeterministicData(count: Chunker.minChunkSizeBytes, seed: 7)
        let fileURL = tempDirectory.appendingPathComponent("exact-4mib.bin")
        try exactFourMiB.write(to: fileURL)

        let filePlan = try Chunker.planFile(at: fileURL, chunkSizeBytes: Chunker.minChunkSizeBytes)
        let dataPlan = try Chunker.planData(exactFourMiB, chunkSizeBytes: Chunker.minChunkSizeBytes)

        XCTAssertEqual(filePlan, dataPlan)
        XCTAssertEqual(filePlan.chunks.count, 1)
        XCTAssertEqual(filePlan.chunks[0].offset, 0)
        XCTAssertEqual(filePlan.chunks[0].length, Chunker.minChunkSizeBytes)
        XCTAssertEqual(filePlan.chunks[0].hash, filePlan.sha256Digest)
    }

    func testNonZeroStartIndexDataSliceMatchesFilePlan() throws {
        let prefixCount = 311
        let payloadCount = Chunker.minChunkSizeBytes + 90_000
        let suffixCount = 197
        let backing = makeDeterministicData(count: prefixCount + payloadCount + suffixCount, seed: 19)

        let slice = backing[prefixCount ..< (prefixCount + payloadCount)]
        XCTAssertEqual(slice.startIndex, prefixCount)

        let fileURL = tempDirectory.appendingPathComponent("slice.bin")
        try Data(slice).write(to: fileURL)

        let slicePlan = try Chunker.planData(slice, chunkSizeBytes: Chunker.minChunkSizeBytes)
        let filePlan = try Chunker.planFile(at: fileURL, chunkSizeBytes: Chunker.minChunkSizeBytes)

        XCTAssertEqual(slicePlan, filePlan)
        XCTAssertEqual(slicePlan.chunks.count, 2)

        for descriptor in slicePlan.chunks {
            let slicedChunk = try Chunker.sliceData(slice, chunk: descriptor)
            let diskChunk = try Chunker.readChunk(from: fileURL, chunk: descriptor)
            XCTAssertEqual(slicedChunk, diskChunk)
            XCTAssertEqual(Chunker.sha256Hex(of: slicedChunk), descriptor.hash)
        }
    }

    func testMultiChunkTenPointFiveMiBPlanAndOnDemandReads() throws {
        let totalSize = 10 * 1024 * 1024 + 512 * 1024 // 10.5 MiB
        let payload = makeDeterministicData(count: totalSize, seed: 42)
        let fileURL = tempDirectory.appendingPathComponent("multi-10.5mib.bin")
        try payload.write(to: fileURL)

        let filePlan = try Chunker.planFile(at: fileURL, chunkSizeBytes: Chunker.minChunkSizeBytes)
        let dataPlan = try Chunker.planData(payload, chunkSizeBytes: Chunker.minChunkSizeBytes)

        XCTAssertEqual(filePlan, dataPlan)
        XCTAssertEqual(filePlan.sizeBytes, UInt64(totalSize))
        XCTAssertEqual(filePlan.sha256Digest, Chunker.sha256Hex(of: payload))
        XCTAssertEqual(filePlan.chunks.count, 3)
        XCTAssertEqual(filePlan.chunks[0].offset, 0)
        XCTAssertEqual(filePlan.chunks[0].length, 4 * 1024 * 1024)
        XCTAssertEqual(filePlan.chunks[1].offset, UInt64(4 * 1024 * 1024))
        XCTAssertEqual(filePlan.chunks[1].length, 4 * 1024 * 1024)
        XCTAssertEqual(filePlan.chunks[2].offset, UInt64(8 * 1024 * 1024))
        XCTAssertEqual(filePlan.chunks[2].length, 2 * 1024 * 1024 + 512 * 1024)

        for chunk in filePlan.chunks {
            let bytes = try Chunker.readChunk(from: fileURL, chunk: chunk)
            XCTAssertEqual(bytes.count, chunk.length)
            XCTAssertEqual(Chunker.sha256Hex(of: bytes), chunk.hash)
        }

        // Also verify non-32KiB-aligned chunkSizeBytes boundary splitting in planFile vs planData.
        let unalignedChunkSize = Chunker.minChunkSizeBytes + 137
        let unalignedFilePlan = try Chunker.planFile(at: fileURL, chunkSizeBytes: unalignedChunkSize)
        let unalignedDataPlan = try Chunker.planData(payload, chunkSizeBytes: unalignedChunkSize)
        XCTAssertEqual(unalignedFilePlan, unalignedDataPlan)
    }

    func testReadChunkPastEOFThrowsAndTaskCancellationPropagates() async throws {
        let payload = Data("short".utf8)
        let fileURL = tempDirectory.appendingPathComponent("short.bin")
        try payload.write(to: fileURL)

        XCTAssertThrowsError(try Chunker.readChunk(from: fileURL, offset: 0, length: 16))

        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Chunker.planData(payload)
        }
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    private func makeDeterministicData(count: Int, seed: UInt64) -> Data {
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var i = 0
            while i + 8 <= count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                var little = state.littleEndian
                withUnsafeBytes(of: &little) { src in
                    base.advanced(by: i).update(from: src.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 8)
                }
                i += 8
            }
            while i < count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                base[i] = UInt8(truncatingIfNeeded: state)
                i += 1
            }
        }
        return data
    }
}
