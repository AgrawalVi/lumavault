import Connect
import Foundation
import SwiftProtobuf
import XCTest
@testable import LumaVaultSDK

final class LumaVaultClientTests: XCTestCase {
    private var tempDirectory: URL!
    private var baseURL: URL!
    private var mockStorage: MockStorageServiceClient!
    private var mockTransport: MockDataPlane!
    private var client: LumaVaultClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumavault-client-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        MockURLProtocol.reset()
        baseURL = URL(string: "https://vault.example.com/")!
        mockStorage = MockStorageServiceClient()
        mockTransport = MockDataPlane(baseURL: baseURL)
        client = LumaVaultClient(
            baseURL: baseURL,
            storageClient: mockStorage,
            transport: mockTransport
        )
    }

    override func tearDownWithError() throws {
        MockURLProtocol.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testFreshMultiChunkUploadFileEnforcesBoundedConcurrencyAndCoalescesProgress() async throws {
        let chunkSize = Chunker.minChunkSizeBytes // 4 MiB
        let totalSize = 4 * chunkSize + 512 * 1024 // 16.5 MiB -> 5 chunks (528 x 32 KiB reads)
        let payload = makeDeterministicData(count: totalSize, seed: 101)
        let fileURL = tempDirectory.appendingPathComponent("vacation.mov")
        try payload.write(to: fileURL)

        let expectedPlan = try Chunker.planData(payload, chunkSizeBytes: chunkSize)
        XCTAssertEqual(expectedPlan.chunks.count, 5)

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, expectedPlan.chunks.map(\.hash))
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = req.chunkHashes
            return ResponseMessage(result: .success(resp))
        }

        let gate = ConcurrencyGate(targetParallelism: 2)
        mockTransport.onPutChunk = { data, hash in
            await gate.enterAndWaitForPair(hash: hash, data: data)
            await gate.leave()
        }

        mockStorage.onCommitObject = { req, _ in
            XCTAssertEqual(req.namespace, .photos)
            XCTAssertEqual(req.filename, "vacation.mov")
            XCTAssertEqual(req.mimeType, "video/quicktime")
            XCTAssertEqual(req.sizeBytes, UInt64(totalSize))
            XCTAssertEqual(req.chunkSizeBytes, UInt32(chunkSize))
            XCTAssertEqual(req.sha256Digest, expectedPlan.sha256Digest)
            XCTAssertEqual(req.chunkHashes, expectedPlan.chunks.map(\.hash))
            XCTAssertEqual(req.thumbnailChunkHash, "")
            XCTAssertFalse(req.skipDedup)

            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-photo-1")
            resp.deduplicated = false
            return ResponseMessage(result: .success(resp))
        }

        let progressBox = LockedBox<[UploadProgress]>([])
        let result = try await client.uploadFile(
            at: fileURL,
            namespace: .photos,
            mimeType: "video/quicktime"
        ) { progress in
            progressBox.withValue { $0.append(progress) }
        }

        XCTAssertEqual(result.object.id, "obj-photo-1")
        XCTAssertFalse(result.deduplicated)

        let uploaded = await gate.uploadedByHash
        let peakActive = await gate.peakActive
        XCTAssertEqual(uploaded.count, 5)
        XCTAssertEqual(peakActive, 2)

        for chunk in expectedPlan.chunks {
            let expectedSlice = try Chunker.sliceData(payload, chunk: chunk)
            XCTAssertEqual(uploaded[chunk.hash], expectedSlice)
        }

        let events = progressBox.value
        let hashingEvents = events.compactMap { event -> (UInt64, UInt64)? in
            if case .hashing(let hashed, let total) = event { return (hashed, total) }
            return nil
        }
        // Coalesced by Chunker at ~1 MiB steps + chunk boundaries + EOF instead of 528 x 32 KiB reads.
        XCTAssertLessThanOrEqual(hashingEvents.count, 24)
        XCTAssertEqual(hashingEvents.last?.0, UInt64(totalSize))
        XCTAssertEqual(hashingEvents.last?.1, UInt64(totalSize))
        XCTAssertTrue(events.contains(.checking(totalChunks: 5)))
        XCTAssertTrue(events.contains(.uploading(completedChunks: 0, totalChunks: 5)))
        XCTAssertTrue(events.contains(.uploading(completedChunks: 5, totalChunks: 5)))
        XCTAssertEqual(events.last, .committing)
    }

    func testFailedChunkUploadAbortsBeforeCommitObject() async throws {
        let chunkSize = Chunker.minChunkSizeBytes
        let payload = makeDeterministicData(count: 3 * chunkSize, seed: 77)
        let plan = try Chunker.planData(payload, chunkSizeBytes: chunkSize)
        let failingHash = plan.chunks[1].hash

        mockStorage.onHasChunks = { req, _ in
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = req.chunkHashes
            return ResponseMessage(result: .success(resp))
        }
        mockTransport.onPutChunk = { _, hash in
            if hash == failingHash {
                throw LumaVaultError.httpError(statusCode: 500, message: "disk full")
            }
        }
        mockStorage.onCommitObject = { _, _ in
            XCTFail("CommitObject must never run when a chunk upload fails")
            return ResponseMessage(result: .success(Lumavault_V1_CommitObjectResponse()))
        }

        do {
            _ = try await client.uploadData(payload, namespace: .photos, filename: "broken.bin")
            XCTFail("Expected httpError(500)")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .httpError(statusCode: 500, message: "disk full"))
        }
        XCTAssertEqual(mockStorage.commitCallCount, 0)
    }

    func testPartialDeduplicationUploadsOnlyMissingChunkOfFour() async throws {
        let chunkSize = Chunker.minChunkSizeBytes
        let chunks = (1 ... 4).map { makeDeterministicData(count: chunkSize, seed: UInt64($0)) }
        let fullSave = chunks.reduce(into: Data(capacity: 4 * chunkSize)) { $0.append($1) }
        let hashes = chunks.map(Chunker.sha256Hex(of:))

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, hashes)
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = [hashes[2]]
            return ResponseMessage(result: .success(resp))
        }

        let putHashes = LockedBox<[String]>([])
        mockTransport.onPutChunk = { data, hash in
            putHashes.withValue { $0.append(hash) }
            XCTAssertEqual(data, chunks[2])
        }

        mockStorage.onCommitObject = { req, _ in
            XCTAssertEqual(req.chunkHashes, hashes)
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-nds-svs")
            return ResponseMessage(result: .success(resp))
        }

        let result = try await client.uploadData(
            fullSave,
            namespace: .games,
            filename: "pokemon.svs"
        )

        XCTAssertEqual(result.object.id, "obj-nds-svs")
        XCTAssertEqual(putHashes.value, [hashes[2]])
    }

    func testFullDeduplicationUploadsZeroChunksAndSkipsUploadingPhase() async throws {
        let data = Data("already-stored-photo-bytes".utf8)
        let hash = Chunker.sha256Hex(of: data)

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, [hash])
            return ResponseMessage(result: .success(Lumavault_V1_HasChunksResponse()))
        }
        mockStorage.onCommitObject = { req, _ in
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-existing")
            resp.deduplicated = true
            return ResponseMessage(result: .success(resp))
        }

        let progressBox = LockedBox<[UploadProgress]>([])
        let result = try await client.uploadData(
            data,
            namespace: .photos,
            filename: "IMG_0001.HEIC"
        ) { progress in
            progressBox.withValue { $0.append(progress) }
        }

        XCTAssertEqual(result.object.id, "obj-existing")
        XCTAssertTrue(result.deduplicated)
        XCTAssertEqual(mockTransport.putCallCount, 0)
        XCTAssertFalse(progressBox.value.contains(where: {
            if case .uploading = $0 { return true }
            return false
        }))
        XCTAssertEqual(progressBox.value.last, .committing)
    }

    func testIntraFileDuplicateChunksDeduplicateHasChunksAndPutWhileCommittingFullManifest() async throws {
        let chunkSize = Chunker.minChunkSizeBytes
        let blockA = makeDeterministicData(count: chunkSize, seed: 11)
        let blockB = makeDeterministicData(count: chunkSize, seed: 22)
        let blockC = Data("tail-chunk-bytes".utf8)

        var payload = Data(capacity: 3 * chunkSize + blockC.count)
        payload.append(blockA)
        payload.append(blockB)
        payload.append(blockA)
        payload.append(blockC)

        let hashA = Chunker.sha256Hex(of: blockA)
        let hashB = Chunker.sha256Hex(of: blockB)
        let hashC = Chunker.sha256Hex(of: blockC)

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, [hashA, hashB, hashC])
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = [hashA, hashB, hashC]
            return ResponseMessage(result: .success(resp))
        }

        let putHashes = LockedBox<[String]>([])
        mockTransport.onPutChunk = { _, hash in
            putHashes.withValue { $0.append(hash) }
        }

        mockStorage.onCommitObject = { req, _ in
            XCTAssertEqual(req.chunkHashes, [hashA, hashB, hashA, hashC])
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-dup-blocks")
            return ResponseMessage(result: .success(resp))
        }

        let result = try await client.uploadData(
            payload,
            namespace: .games,
            filename: "padded.rom"
        )

        XCTAssertEqual(result.object.id, "obj-dup-blocks")
        XCTAssertEqual(Set(putHashes.value), Set([hashA, hashB, hashC]))
        XCTAssertEqual(putHashes.value.count, 3)
    }

    func testZeroByteFastPathSkipsHasChunksAndUploadsWhenNoThumbnail() async throws {
        let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let emptyFile = tempDirectory.appendingPathComponent("empty.txt")
        try Data().write(to: emptyFile)

        mockStorage.onHasChunks = { _, _ in
            XCTFail("HasChunks must not be called for 0-byte upload without thumbnail")
            return ResponseMessage(result: .success(Lumavault_V1_HasChunksResponse()))
        }
        mockStorage.onCommitObject = { req, _ in
            XCTAssertEqual(req.sizeBytes, 0)
            XCTAssertTrue(req.chunkHashes.isEmpty)
            XCTAssertEqual(req.sha256Digest, emptySHA256)
            XCTAssertEqual(req.thumbnailChunkHash, "")
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-empty")
            return ResponseMessage(result: .success(resp))
        }

        let progressBox = LockedBox<[UploadProgress]>([])
        let fileResult = try await client.uploadFile(at: emptyFile, namespace: .photos) { progress in
            progressBox.withValue { $0.append(progress) }
        }
        let dataResult = try await client.uploadData(Data(), namespace: .photos, filename: "empty.txt")

        XCTAssertEqual(fileResult.object.id, "obj-empty")
        XCTAssertEqual(dataResult.object.id, "obj-empty")
        XCTAssertEqual(mockStorage.hasChunksCallCount, 0)
        XCTAssertEqual(mockTransport.putCallCount, 0)
        XCTAssertEqual(
            progressBox.value,
            [.hashing(bytesHashed: 0, totalBytes: 0), .committing]
        )
    }

    func testThumbnailUploadOversizedGuardAndURLHelpers() async throws {
        let oversizedThumb = Data(count: Chunker.maxChunkSizeBytes + 1)
        do {
            _ = try await client.uploadData(
                Data("photo".utf8),
                namespace: .photos,
                filename: "IMG.HEIC",
                thumbnail: oversizedThumb
            )
            XCTFail("Expected payloadTooLarge")
        } catch let error as LumaVaultError {
            XCTAssertEqual(
                error,
                .payloadTooLarge(
                    sizeBytes: Int64(Chunker.maxChunkSizeBytes + 1),
                    maxBytes: Int64(Chunker.maxChunkSizeBytes)
                )
            )
        }
        XCTAssertEqual(mockStorage.hasChunksCallCount, 0)

        let photoBytes = Data("heic-image-payload".utf8)
        let thumbBytes = Data("jpeg-thumbnail-payload".utf8)
        let photoHash = Chunker.sha256Hex(of: photoBytes)
        let thumbHash = Chunker.sha256Hex(of: thumbBytes)

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, [photoHash, thumbHash])
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = [thumbHash]
            return ResponseMessage(result: .success(resp))
        }
        mockTransport.onPutChunk = { data, hash in
            XCTAssertEqual(hash, thumbHash)
            XCTAssertEqual(data, thumbBytes)
        }
        mockTransport.onGetChunk = { hash, verify in
            XCTAssertEqual(hash, thumbHash)
            XCTAssertTrue(verify)
            return thumbBytes
        }
        mockStorage.onCommitObject = { req, _ in
            XCTAssertEqual(req.chunkHashes, [photoHash])
            XCTAssertEqual(req.thumbnailChunkHash, thumbHash)
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-with-thumb")
            return ResponseMessage(result: .success(resp))
        }

        let result = try await client.uploadData(
            photoBytes,
            namespace: .photos,
            filename: "IMG_2048.HEIC",
            mimeType: "image/heic",
            thumbnail: thumbBytes
        )

        XCTAssertEqual(mockTransport.putCallCount, 1)
        let fetchedThumb = try await client.getChunk(hash: thumbHash)
        XCTAssertEqual(fetchedThumb, thumbBytes)
        XCTAssertEqual(
            client.thumbnailURL(for: result.object)?.absoluteString,
            "https://vault.example.com/v1/chunks/\(thumbHash)"
        )
        XCTAssertEqual(
            client.streamURL(forObjectID: result.object.id).absoluteString,
            "https://vault.example.com/v1/stream/obj-with-thumb"
        )
        XCTAssertEqual(
            client.chunkURL(forHash: photoHash).absoluteString,
            "https://vault.example.com/v1/chunks/\(photoHash)"
        )

        var withoutThumb = result.object
        withoutThumb.thumbnailChunkHash = ""
        XCTAssertNil(client.thumbnailURL(for: withoutThumb))
    }

    func testSkipDedupTrueCommitsDistinctVersionedGameSaves() async throws {
        let sramBytes = Data("zelda-battery-sram-32k".utf8)
        let sramHash = Chunker.sha256Hex(of: sramBytes)
        let storedChunks = LockedBox<Set<String>>([])
        let commitCount = LockedBox<Int>(0)

        mockStorage.onHasChunks = { req, _ in
            let current = storedChunks.value
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = req.chunkHashes.filter { !current.contains($0) }
            return ResponseMessage(result: .success(resp))
        }
        mockTransport.onPutChunk = { _, hash in
            storedChunks.withValue { _ = $0.insert(hash) }
        }
        mockStorage.onCommitObject = { req, _ in
            XCTAssertTrue(req.skipDedup)
            XCTAssertEqual(req.sha256Digest, sramHash)
            let version = commitCount.withValue { count -> Int in
                count += 1
                return count
            }
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "save-v\(version)")
            resp.deduplicated = false
            return ResponseMessage(result: .success(resp))
        }

        let v1 = try await client.uploadData(
            sramBytes,
            namespace: .games,
            filename: "minish_cap.sav",
            skipDedup: true
        )
        let v2 = try await client.uploadData(
            sramBytes,
            namespace: .games,
            filename: "minish_cap.sav",
            skipDedup: true
        )

        XCTAssertEqual(v1.object.id, "save-v1")
        XCTAssertEqual(v2.object.id, "save-v2")
        XCTAssertFalse(v1.deduplicated)
        XCTAssertFalse(v2.deduplicated)
        XCTAssertEqual(mockTransport.putCallCount, 1)
    }

    func testUpdateObjectMetadataBuildsFieldMaskAndRejectsEmptyMask() async throws {
        do {
            _ = try await client.updateObjectMetadata(objectID: "obj-1")
            XCTFail("Expected emptyUpdateMask")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .emptyUpdateMask)
        }
        XCTAssertEqual(mockStorage.updateCallCount, 0)

        do {
            _ = try await client.updateObjectMetadata(objectID: "obj-1", thumbnailChunkHash: "invalid")
            XCTFail("Expected invalidHash")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .invalidHash("invalid"))
        }
        XCTAssertEqual(mockStorage.updateCallCount, 0)

        let validThumb = String(repeating: "b", count: 64)
        mockStorage.onUpdateObjectMetadata = { req, _ in
            XCTAssertEqual(req.object.id, "obj-1")
            XCTAssertEqual(req.object.filename, "renamed.mp4")
            XCTAssertEqual(req.object.mimeType, "video/mp4")
            XCTAssertEqual(req.object.thumbnailChunkHash, validThumb)
            XCTAssertEqual(req.updateMask.paths, ["filename", "mime_type", "thumbnail_chunk_hash"])
            var resp = Lumavault_V1_UpdateObjectMetadataResponse()
            resp.object = req.object
            return ResponseMessage(result: .success(resp))
        }

        let updated = try await client.updateObjectMetadata(
            objectID: "obj-1",
            filename: "renamed.mp4",
            mimeType: "video/mp4",
            thumbnailChunkHash: validThumb
        )
        XCTAssertEqual(updated.filename, "renamed.mp4")
        XCTAssertEqual(updated.thumbnailChunkHash, validThumb)

        mockStorage.onUpdateObjectMetadata = { req, _ in
            XCTAssertEqual(req.updateMask.paths, ["thumbnail_chunk_hash"])
            XCTAssertEqual(req.object.thumbnailChunkHash, "")
            var resp = Lumavault_V1_UpdateObjectMetadataResponse()
            resp.object = req.object
            return ResponseMessage(result: .success(resp))
        }
        let cleared = try await client.updateObjectMetadata(objectID: "obj-1", thumbnailChunkHash: "")
        XCTAssertEqual(cleared.thumbnailChunkHash, "")
    }

    func testListAllObjectsDemandDrivenBackpressureEarlyBreakAndCycleGuard() async throws {
        do {
            _ = try await client.listObjects(namespace: .cinema, pageSize: -1)
            XCTFail("Expected invalidArgument for negative pageSize")
        } catch let error as LumaVaultError {
            guard case .invalidArgument = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let requestedTokens = LockedBox<[String]>([])
        mockStorage.onListObjects = { req, _ in
            XCTAssertEqual(req.namespace, .cinema)
            XCTAssertEqual(req.pageSize, 2)
            requestedTokens.withValue { $0.append(req.pageToken) }

            var resp = Lumavault_V1_ListObjectsResponse()
            switch req.pageToken {
            case "":
                resp.objects = [Self.stubObject(id: "m1"), Self.stubObject(id: "m2")]
                resp.nextPageToken = "cursor-1"
            case "cursor-1":
                resp.objects = [Self.stubObject(id: "m3"), Self.stubObject(id: "m4")]
                resp.nextPageToken = "cursor-2"
            case "cursor-2":
                resp.objects = [Self.stubObject(id: "m5")]
                resp.nextPageToken = ""
            default:
                XCTFail("Unexpected pageToken: \(req.pageToken)")
            }
            return ResponseMessage(result: .success(resp))
        }

        var collectedIDs: [String] = []
        for try await obj in client.listAllObjects(namespace: .cinema, pageSize: 2) {
            collectedIDs.append(obj.id)
        }
        XCTAssertEqual(collectedIDs, ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertEqual(requestedTokens.value, ["", "cursor-1", "cursor-2"])

        // Breaking on the first item of page 1 never requests page 2 (strict demand-driven backpressure).
        requestedTokens.withValue { $0.removeAll() }
        var firstOnly: [String] = []
        for try await obj in client.listAllObjects(namespace: .cinema, pageSize: 2) {
            firstOnly.append(obj.id)
            break
        }
        XCTAssertEqual(firstOnly, ["m1"])
        XCTAssertEqual(requestedTokens.value, [""])

        // Repeating next_page_token fails with invalidResponse instead of looping infinitely.
        mockStorage.onListObjects = { _, _ in
            var resp = Lumavault_V1_ListObjectsResponse()
            resp.objects = [Self.stubObject(id: "dup")]
            resp.nextPageToken = "stuck-token"
            return ResponseMessage(result: .success(resp))
        }
        do {
            for try await _ in client.listAllObjects(namespace: .cinema, pageSize: 1) {}
            XCTFail("Expected invalidResponse on repeating cursor token")
        } catch let error as LumaVaultError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testVerifiedDownloadsErrorMappingCancellationAndWireRoundTrip() async throws {
        do {
            _ = try await client.getObject(objectID: "")
            XCTFail("Expected invalidArgument for empty objectID")
        } catch let error as LumaVaultError {
            guard case .invalidArgument = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let realDataPlane = DataPlaneClient(baseURL: baseURL, session: session)
        let wiredDataClient = LumaVaultClient(
            baseURL: baseURL,
            storageClient: mockStorage,
            dataPlane: realDataPlane
        )

        let romBytes = Data((0 ..< 72 * 1024).map { UInt8(($0 * 7) & 0xFF) })
        let romHash = Chunker.sha256Hex(of: romBytes)

        var metadata = Lumavault_V1_ObjectMetadata()
        metadata.id = "rom-emerald"
        metadata.namespace = .games
        metadata.sizeBytes = UInt64(romBytes.count)
        metadata.sha256Digest = romHash

        mockStorage.onGetObject = { _, _ in
            XCTFail("Downloads must not issue an extra GetObject RPC")
            return ResponseMessage(result: .failure(ConnectError(code: .internalError, message: "unexpected")))
        }

        // 1. ObjectMetadata download verifies metadata.sha256Digest without ETag or GetObject.
        MockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/stream/rom-emerald")
            return MockResponse(statusCode: 200, headers: [:], body: romBytes)
        }
        let fileDest1 = tempDirectory.appendingPathComponent("emerald-meta.gba")
        try await wiredDataClient.downloadObjectToFile(metadata, to: fileDest1)
        XCTAssertEqual(try Data(contentsOf: fileDest1), romBytes)
        let memData1 = try await wiredDataClient.downloadObjectData(metadata)
        XCTAssertEqual(memData1, romBytes)

        // Fast-fail maxBytes check on ObjectMetadata.sizeBytes without hitting HTTP.
        let beforeCap = MockURLProtocol.requestCount
        do {
            _ = try await wiredDataClient.downloadObjectData(metadata, maxBytes: 1024)
            XCTFail("Expected payloadTooLarge")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .payloadTooLarge(sizeBytes: Int64(romBytes.count), maxBytes: 1024))
        }
        XCTAssertEqual(MockURLProtocol.requestCount, beforeCap)

        // 2. objectID download + unset-digest ObjectMetadata fallback verify against quoted ETag.
        MockURLProtocol.setHandler { _, _ in
            MockResponse(statusCode: 200, headers: ["ETag": "\"\(romHash)\""], body: romBytes)
        }
        let fileDest2 = tempDirectory.appendingPathComponent("emerald-id.gba")
        try await wiredDataClient.downloadObjectToFile(objectID: "rom-emerald", to: fileDest2)
        XCTAssertEqual(try Data(contentsOf: fileDest2), romBytes)

        var unsetDigestMeta = Lumavault_V1_ObjectMetadata()
        unsetDigestMeta.id = "rom-emerald"
        let fallbackData = try await wiredDataClient.downloadObjectData(unsetDigestMeta)
        XCTAssertEqual(fallbackData, romBytes)
        XCTAssertEqual(mockStorage.getObjectCallCount, 0)

        // 3. Cancellation normalization across Data Plane (URLError.cancelled -> CancellationError).
        mockTransport.onDownloadData = { _, _, _ in
            throw URLError(.cancelled)
        }
        let localClient = self.client!
        let cancelledDataTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await localClient.downloadObjectData(objectID: "rom-emerald")
        }
        do {
            _ = try await cancelledDataTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {}

        // 4. Connect error mapping, header forwarding, deleteObject, and convenience init wire round-trip.
        mockStorage.onGetObject = { _, headers in
            XCTAssertEqual(headers["x-trace-id"], ["trace-42"])
            return ResponseMessage(
                code: .notFound,
                result: .failure(ConnectError(code: .notFound, message: "object missing"))
            )
        }
        do {
            _ = try await client.getObject(objectID: "missing-id", headers: ["X-Trace-Id": "trace-42"])
            XCTFail("Expected rpcError")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .rpcError(code: .notFound, message: "object missing"))
        }

        mockStorage.onDeleteObject = { req, _ in
            XCTAssertEqual(req.objectID, "del-1")
            return ResponseMessage(result: .success(Lumavault_V1_DeleteObjectResponse()))
        }
        try await client.deleteObject(objectID: "del-1")

        let wireClient = LumaVaultClient(
            baseURL: URL(string: "https://vault.example.com/prefix///")!,
            configuration: config
        )
        var wireResp = Lumavault_V1_GetObjectResponse()
        wireResp.object = Self.stubObject(id: "wire-obj-1")
        let serializedResp = try wireResp.serializedData()

        MockURLProtocol.setHandler { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/prefix/lumavault.v1.StorageService/GetObject")
            let decodedReq = try Lumavault_V1_GetObjectRequest(serializedBytes: body)
            XCTAssertEqual(decodedReq.objectID, "wire-obj-1")
            return MockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/proto"],
                body: serializedResp
            )
        }
        let fetched = try await wireClient.getObject(objectID: "wire-obj-1")
        XCTAssertEqual(fetched.id, "wire-obj-1")
    }

    // MARK: - Fixture Helpers

    private static func makeObject(
        from req: Lumavault_V1_CommitObjectRequest,
        id: String
    ) -> Lumavault_V1_ObjectMetadata {
        var obj = Lumavault_V1_ObjectMetadata()
        obj.id = id
        obj.namespace = req.namespace
        obj.filename = req.filename
        obj.mimeType = req.mimeType
        obj.sizeBytes = req.sizeBytes
        obj.chunkSizeBytes = req.chunkSizeBytes
        obj.sha256Digest = req.sha256Digest
        obj.chunkHashes = req.chunkHashes
        obj.thumbnailChunkHash = req.thumbnailChunkHash
        return obj
    }

    private static func stubObject(id: String) -> Lumavault_V1_ObjectMetadata {
        var obj = Lumavault_V1_ObjectMetadata()
        obj.id = id
        obj.namespace = .cinema
        obj.sha256Digest = String(repeating: "a", count: 64)
        return obj
    }

    private func makeDeterministicData(count: Int, seed: UInt64) -> Data {
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i + 8 <= count {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                base.advanced(by: i).withMemoryRebound(to: UInt64.self, capacity: 1) { $0.pointee = state.littleEndian }
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

// MARK: - Test Doubles

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) { self.storage = initial }

    var value: T { lock.withLock { storage } }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

private actor ConcurrencyGate {
    private let targetParallelism: Int
    private var active = 0
    private(set) var peakActive = 0
    private(set) var uploadedByHash: [String: Data] = [:]
    private var pairSatisfied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(targetParallelism: Int) {
        self.targetParallelism = targetParallelism
    }

    func enterAndWaitForPair(hash: String, data: Data) async {
        active += 1
        if active > peakActive {
            peakActive = active
        }
        uploadedByHash[hash] = data

        if pairSatisfied {
            return
        }
        if active >= targetParallelism {
            pairSatisfied = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        active -= 1
    }
}

private final class MockDataPlane: DataPlaneTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let urlBuilder: DataPlaneClient

    var onPutChunk: (@Sendable (Data, String) async throws -> Void)?
    var onGetChunk: (@Sendable (String, Bool) async throws -> Data)?
    var onDownloadFile: (@Sendable (String, URL, String?) async throws -> Void)?
    var onDownloadData: (@Sendable (String, String?, Int64) async throws -> Data)?
    private(set) var putCallCount = 0

    init(baseURL: URL) {
        self.urlBuilder = DataPlaneClient(baseURL: baseURL, configuration: .ephemeral)
    }

    func streamURL(forObjectID objectID: String) -> URL {
        urlBuilder.streamURL(forObjectID: objectID)
    }

    func chunkURL(forHash hash: String) -> URL {
        urlBuilder.chunkURL(forHash: hash)
    }

    func putChunk(data: Data, hash: String) async throws {
        let handler = lock.withLock {
            putCallCount += 1
            return onPutChunk
        }
        try await handler?(data, hash)
    }

    func getChunk(hash: String, verifyHash: Bool) async throws -> Data {
        let handler = lock.withLock { onGetChunk }
        return try await handler?(hash, verifyHash) ?? Data()
    }

    func downloadStreamToFile(objectID: String, to destinationURL: URL, expectedSHA256: String?) async throws {
        let handler = lock.withLock { onDownloadFile }
        try await handler?(objectID, destinationURL, expectedSHA256)
    }

    func downloadStreamData(objectID: String, expectedSHA256: String?, maxBytes: Int64) async throws -> Data {
        let handler = lock.withLock { onDownloadData }
        return try await handler?(objectID, expectedSHA256, maxBytes) ?? Data()
    }
}

private final class MockStorageServiceClient: Lumavault_V1_StorageServiceClientInterface, @unchecked Sendable {
    private let lock = NSLock()

    var onHasChunks: (@Sendable (Lumavault_V1_HasChunksRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_HasChunksResponse>)?
    var onCommitObject: (@Sendable (Lumavault_V1_CommitObjectRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_CommitObjectResponse>)?
    var onGetObject: (@Sendable (Lumavault_V1_GetObjectRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_GetObjectResponse>)?
    var onListObjects: (@Sendable (Lumavault_V1_ListObjectsRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_ListObjectsResponse>)?
    var onUpdateObjectMetadata: (@Sendable (Lumavault_V1_UpdateObjectMetadataRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_UpdateObjectMetadataResponse>)?
    var onDeleteObject: (@Sendable (Lumavault_V1_DeleteObjectRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_DeleteObjectResponse>)?

    private(set) var hasChunksCallCount = 0
    private(set) var commitCallCount = 0
    private(set) var getObjectCallCount = 0
    private(set) var updateCallCount = 0

    func hasChunks(request: Lumavault_V1_HasChunksRequest, headers: Connect.Headers) async -> ResponseMessage<Lumavault_V1_HasChunksResponse> {
        guard let handler = lock.withLock({ hasChunksCallCount += 1; return onHasChunks }) else {
            return Self.unimplemented()
        }
        return await handler(request, headers)
    }

    func commitObject(request: Lumavault_V1_CommitObjectRequest, headers: Connect.Headers) async -> ResponseMessage<Lumavault_V1_CommitObjectResponse> {
        guard let handler = lock.withLock({ commitCallCount += 1; return onCommitObject }) else {
            return Self.unimplemented()
        }
        return await handler(request, headers)
    }

    func getObject(request: Lumavault_V1_GetObjectRequest, headers: Connect.Headers) async -> ResponseMessage<Lumavault_V1_GetObjectResponse> {
        guard let handler = lock.withLock({ getObjectCallCount += 1; return onGetObject }) else {
            return Self.unimplemented()
        }
        return await handler(request, headers)
    }

    func listObjects(request: Lumavault_V1_ListObjectsRequest, headers: Connect.Headers) async -> ResponseMessage<Lumavault_V1_ListObjectsResponse> {
        guard let handler = lock.withLock({ onListObjects }) else {
            return Self.unimplemented()
        }
        return await handler(request, headers)
    }

    func updateObjectMetadata(request: Lumavault_V1_UpdateObjectMetadataRequest, headers: Connect.Headers) async -> ResponseMessage<Lumavault_V1_UpdateObjectMetadataResponse> {
        guard let handler = lock.withLock({ updateCallCount += 1; return onUpdateObjectMetadata }) else {
            return Self.unimplemented()
        }
        return await handler(request, headers)
    }

    func deleteObject(request: Lumavault_V1_DeleteObjectRequest, headers: Connect.Headers) async -> ResponseMessage<Lumavault_V1_DeleteObjectResponse> {
        guard let handler = lock.withLock({ onDeleteObject }) else {
            return Self.unimplemented()
        }
        return await handler(request, headers)
    }

    private static func unimplemented<T: ProtobufMessage>() -> ResponseMessage<T> {
        ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
    }
}
