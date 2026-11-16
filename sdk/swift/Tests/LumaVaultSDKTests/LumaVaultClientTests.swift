import Connect
import Foundation
import SwiftProtobuf
import XCTest
@testable import LumaVaultSDK

final class LumaVaultClientTests: XCTestCase {
    private var tempDirectory: URL!
    private var config: URLSessionConfiguration!
    private var session: URLSession!
    private var mockStorage: MockStorageServiceClient!
    private var client: LumaVaultClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumavault-client-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        ClientMockURLProtocol.reset()
        config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClientMockURLProtocol.self]
        session = URLSession(configuration: config)
        mockStorage = MockStorageServiceClient()

        let baseURL = URL(string: "https://vault.example.com/")!
        let dataPlane = DataPlaneClient(baseURL: baseURL, session: session)
        client = LumaVaultClient(
            baseURL: baseURL,
            storageClient: mockStorage,
            dataPlane: dataPlane
        )
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        ClientMockURLProtocol.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testFreshMultiChunkUploadFileEnforcesBoundedConcurrencyAndEmitsProgress() async throws {
        let chunkSize = Chunker.minChunkSizeBytes // 4 MiB
        let totalSize = 4 * chunkSize + 512 * 1024 // 16.5 MiB -> 5 chunks
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

        let uploadTracker = UploadTracker()
        ClientMockURLProtocol.setHandler { request, body in
            XCTAssertEqual(request.httpMethod, "PUT")
            let hash = request.url!.lastPathComponent
            uploadTracker.enter(hash: hash, data: body)
            Thread.sleep(forTimeInterval: 0.02)
            uploadTracker.leave()
            return ClientMockResponse(statusCode: 201)
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

            var obj = Self.makeObject(from: req, id: "obj-photo-1")
            obj.createdAt = Google_Protobuf_Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000))
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = obj
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
        XCTAssertEqual(uploadTracker.uploadedByHash.count, 5)
        XCTAssertLessThanOrEqual(uploadTracker.peakActive, 2)
        XCTAssertEqual(uploadTracker.peakActive, 2)

        for chunk in expectedPlan.chunks {
            let expectedSlice = try Chunker.sliceData(payload, chunk: chunk)
            XCTAssertEqual(uploadTracker.uploadedByHash[chunk.hash], expectedSlice)
        }

        let events = progressBox.value
        XCTAssertTrue(events.contains(where: {
            if case .hashing(_, let total) = $0 { return total == UInt64(totalSize) }
            return false
        }))
        XCTAssertTrue(events.contains(.checking(totalChunks: 5)))
        XCTAssertTrue(events.contains(.uploading(completedChunks: 0, totalChunks: 5)))
        XCTAssertTrue(events.contains(.uploading(completedChunks: 5, totalChunks: 5)))
        XCTAssertEqual(events.last, .committing)
    }

    func testPartialDeduplicationUploadsOnlyMissingChunkOfFour() async throws {
        let chunkSize = Chunker.minChunkSizeBytes
        let c0 = makeDeterministicData(count: chunkSize, seed: 1)
        let c1 = makeDeterministicData(count: chunkSize, seed: 2)
        let c2 = makeDeterministicData(count: chunkSize, seed: 3)
        let c3 = makeDeterministicData(count: chunkSize, seed: 4)

        var fullSave = Data(capacity: 4 * chunkSize)
        fullSave.append(c0)
        fullSave.append(c1)
        fullSave.append(c2)
        fullSave.append(c3)

        let hashes = [c0, c1, c2, c3].map(Chunker.sha256Hex(of:))

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, hashes)
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = [hashes[2]]
            return ResponseMessage(result: .success(resp))
        }

        let putHashes = LockedBox<[String]>([])
        ClientMockURLProtocol.setHandler { request, body in
            let hash = request.url!.lastPathComponent
            putHashes.withValue { $0.append(hash) }
            XCTAssertEqual(body, c2)
            return ClientMockResponse(statusCode: 201)
        }

        mockStorage.onCommitObject = { req, _ in
            XCTAssertEqual(req.chunkHashes, hashes)
            var resp = Lumavault_V1_CommitObjectResponse()
            resp.object = Self.makeObject(from: req, id: "obj-nds-svs")
            resp.deduplicated = false
            return ResponseMessage(result: .success(resp))
        }

        let result = try await client.uploadData(
            fullSave,
            namespace: .games,
            filename: "pokemon.svs"
        )

        XCTAssertEqual(result.object.id, "obj-nds-svs")
        XCTAssertEqual(putHashes.value, [hashes[2]])
        XCTAssertEqual(ClientMockURLProtocol.requestCount, 1)
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
        XCTAssertEqual(ClientMockURLProtocol.requestCount, 0)
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
        payload.append(blockA) // Exact repeated 4 MiB chunk inside the same file
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
        ClientMockURLProtocol.setHandler { request, _ in
            putHashes.withValue { $0.append(request.url!.lastPathComponent) }
            return ClientMockResponse(statusCode: 201)
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
        XCTAssertEqual(ClientMockURLProtocol.requestCount, 0)
        XCTAssertEqual(
            progressBox.value,
            [.hashing(bytesHashed: 0, totalBytes: 0), .committing]
        )
    }

    func testThumbnailUploadAndURLHelpers() async throws {
        let photoBytes = Data("heic-image-payload".utf8)
        let thumbBytes = Data("jpeg-thumbnail-payload".utf8)
        let photoHash = Chunker.sha256Hex(of: photoBytes)
        let thumbHash = Chunker.sha256Hex(of: thumbBytes)

        mockStorage.onHasChunks = { req, _ in
            XCTAssertEqual(req.chunkHashes, [photoHash, thumbHash])
            var resp = Lumavault_V1_HasChunksResponse()
            resp.missingChunkHashes = [thumbHash] // Main chunk exists, only thumbnail missing
            return ResponseMessage(result: .success(resp))
        }

        ClientMockURLProtocol.setHandler { request, body in
            XCTAssertEqual(request.url?.path, "/v1/chunks/\(thumbHash)")
            XCTAssertEqual(body, thumbBytes)
            return ClientMockResponse(statusCode: 201)
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

        XCTAssertEqual(ClientMockURLProtocol.requestCount, 1)
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

        ClientMockURLProtocol.setHandler { request, _ in
            let hash = request.url!.lastPathComponent
            storedChunks.withValue { _ = $0.insert(hash) }
            return ClientMockResponse(statusCode: 201)
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
        XCTAssertEqual(ClientMockURLProtocol.requestCount, 1)
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
            _ = try await client.updateObjectMetadata(
                objectID: "obj-1",
                thumbnailChunkHash: "invalid"
            )
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
            XCTAssertEqual(
                req.updateMask.paths,
                ["filename", "mime_type", "thumbnail_chunk_hash"]
            )
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

        // Clearing thumbnailChunkHash with "" is allowed.
        mockStorage.onUpdateObjectMetadata = { req, _ in
            XCTAssertEqual(req.updateMask.paths, ["thumbnail_chunk_hash"])
            XCTAssertEqual(req.object.thumbnailChunkHash, "")
            var resp = Lumavault_V1_UpdateObjectMetadataResponse()
            resp.object = req.object
            return ResponseMessage(result: .success(resp))
        }
        let cleared = try await client.updateObjectMetadata(
            objectID: "obj-1",
            thumbnailChunkHash: ""
        )
        XCTAssertEqual(cleared.thumbnailChunkHash, "")
    }

    func testListAllObjectsStreamsAcrossPagesAndCancelsProducerOnEarlyBreak() async throws {
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

        // Early break cancels producer task before subsequent pages execute.
        let gateEntered = expectation(description: "page 2 entered or skipped")
        gateEntered.isInverted = true
        let earlyTokens = LockedBox<[String]>([])

        mockStorage.onListObjects = { req, _ in
            earlyTokens.withValue { $0.append(req.pageToken) }
            if req.pageToken == "cursor-1" {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !Task.isCancelled {
                    gateEntered.fulfill()
                }
                return ResponseMessage(result: .failure(.canceled()))
            }
            var resp = Lumavault_V1_ListObjectsResponse()
            resp.objects = [Self.stubObject(id: "first"), Self.stubObject(id: "second")]
            resp.nextPageToken = "cursor-1"
            return ResponseMessage(result: .success(resp))
        }

        var firstOnly: [String] = []
        for try await obj in client.listAllObjects(namespace: .cinema, pageSize: 2) {
            firstOnly.append(obj.id)
            break
        }
        XCTAssertEqual(firstOnly, ["first"])
        await fulfillment(of: [gateEntered], timeout: 0.25)
    }

    func testVerifiedDownloadsViaObjectMetadataAndObjectIDWithoutExtraGetObject() async throws {
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

        // 1. Download via ObjectMetadata (verifies metadata.sha256Digest even without ETag header).
        ClientMockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/stream/rom-emerald")
            return ClientMockResponse(statusCode: 200, headers: [:], body: romBytes)
        }

        let fileDest1 = tempDirectory.appendingPathComponent("emerald-meta.gba")
        try await client.downloadObjectToFile(metadata, to: fileDest1)
        XCTAssertEqual(try Data(contentsOf: fileDest1), romBytes)

        let memData1 = try await client.downloadObjectData(metadata)
        XCTAssertEqual(memData1, romBytes)

        // Fast-fail maxBytes check on ObjectMetadata.sizeBytes without hitting HTTP.
        let countBeforeCap = ClientMockURLProtocol.requestCount
        do {
            _ = try await client.downloadObjectData(metadata, maxBytes: 1024)
            XCTFail("Expected payloadTooLarge")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .payloadTooLarge(sizeBytes: Int64(romBytes.count), maxBytes: 1024))
        }
        XCTAssertEqual(ClientMockURLProtocol.requestCount, countBeforeCap)

        // 2. Download via objectID + quoted ETag header.
        ClientMockURLProtocol.setHandler { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/stream/rom-emerald")
            return ClientMockResponse(
                statusCode: 200,
                headers: ["ETag": "\"\(romHash)\""],
                body: romBytes
            )
        }

        let fileDest2 = tempDirectory.appendingPathComponent("emerald-id.gba")
        try await client.downloadObjectToFile(objectID: "rom-emerald", to: fileDest2)
        XCTAssertEqual(try Data(contentsOf: fileDest2), romBytes)

        let memData2 = try await client.downloadObjectData(objectID: "rom-emerald")
        XCTAssertEqual(memData2, romBytes)
        XCTAssertEqual(mockStorage.getObjectCallCount, 0)
    }

    func testControlPlaneErrorMappingAndConvenienceInitializerWireRoundTrip() async throws {
        mockStorage.onGetObject = { _, _ in
            ResponseMessage(
                code: .notFound,
                result: .failure(ConnectError(code: .notFound, message: "object missing"))
            )
        }
        do {
            _ = try await client.getObject(objectID: "missing-id")
            XCTFail("Expected rpcError")
        } catch let error as LumaVaultError {
            XCTAssertEqual(error, .rpcError(code: .notFound, message: "object missing"))
        }

        mockStorage.onDeleteObject = { req, _ in
            XCTAssertEqual(req.objectID, "del-1")
            return ResponseMessage(result: .success(Lumavault_V1_DeleteObjectResponse()))
        }
        try await client.deleteObject(objectID: "del-1")

        // Exercise convenience init(baseURL:configuration:) end-to-end through Connect-Swift + URLSessionHTTPClient.
        let wireClient = LumaVaultClient(
            baseURL: URL(string: "https://vault.example.com/prefix///")!,
            configuration: config
        )

        let expectedObj = Self.stubObject(id: "wire-obj-1")
        var wireResp = Lumavault_V1_GetObjectResponse()
        wireResp.object = expectedObj
        let serializedResp = try wireResp.serializedData()

        ClientMockURLProtocol.setHandler { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/prefix/lumavault.v1.StorageService/GetObject"
            )
            let decodedReq = try Lumavault_V1_GetObjectRequest(serializedBytes: body)
            XCTAssertEqual(decodedReq.objectID, "wire-obj-1")
            return ClientMockResponse(
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
                    base.advanced(by: i).update(
                        from: src.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        count: 8
                    )
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

// MARK: - Thread-Safe Test Doubles

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

private final class UploadTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var peakActive = 0
    private(set) var uploadedByHash: [String: Data] = [:]

    func enter(hash: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        if active > peakActive {
            peakActive = active
        }
        uploadedByHash[hash] = data
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
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
    private(set) var getObjectCallCount = 0
    private(set) var updateCallCount = 0

    func hasChunks(
        request: Lumavault_V1_HasChunksRequest,
        headers: Connect.Headers
    ) async -> ResponseMessage<Lumavault_V1_HasChunksResponse> {
        let handler: (@Sendable (Lumavault_V1_HasChunksRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_HasChunksResponse>)? = {
            lock.lock()
            defer { lock.unlock() }
            hasChunksCallCount += 1
            return onHasChunks
        }()
        guard let handler else {
            return ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
        }
        return await handler(request, headers)
    }

    func commitObject(
        request: Lumavault_V1_CommitObjectRequest,
        headers: Connect.Headers
    ) async -> ResponseMessage<Lumavault_V1_CommitObjectResponse> {
        let handler = lock.withLock { onCommitObject }
        guard let handler else {
            return ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
        }
        return await handler(request, headers)
    }

    func getObject(
        request: Lumavault_V1_GetObjectRequest,
        headers: Connect.Headers
    ) async -> ResponseMessage<Lumavault_V1_GetObjectResponse> {
        let handler: (@Sendable (Lumavault_V1_GetObjectRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_GetObjectResponse>)? = {
            lock.lock()
            defer { lock.unlock() }
            getObjectCallCount += 1
            return onGetObject
        }()
        guard let handler else {
            return ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
        }
        return await handler(request, headers)
    }

    func listObjects(
        request: Lumavault_V1_ListObjectsRequest,
        headers: Connect.Headers
    ) async -> ResponseMessage<Lumavault_V1_ListObjectsResponse> {
        let handler = lock.withLock { onListObjects }
        guard let handler else {
            return ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
        }
        return await handler(request, headers)
    }

    func updateObjectMetadata(
        request: Lumavault_V1_UpdateObjectMetadataRequest,
        headers: Connect.Headers
    ) async -> ResponseMessage<Lumavault_V1_UpdateObjectMetadataResponse> {
        let handler: (@Sendable (Lumavault_V1_UpdateObjectMetadataRequest, Connect.Headers) async -> ResponseMessage<Lumavault_V1_UpdateObjectMetadataResponse>)? = {
            lock.lock()
            defer { lock.unlock() }
            updateCallCount += 1
            return onUpdateObjectMetadata
        }()
        guard let handler else {
            return ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
        }
        return await handler(request, headers)
    }

    func deleteObject(
        request: Lumavault_V1_DeleteObjectRequest,
        headers: Connect.Headers
    ) async -> ResponseMessage<Lumavault_V1_DeleteObjectResponse> {
        let handler = lock.withLock { onDeleteObject }
        guard let handler else {
            return ResponseMessage(code: .unimplemented, result: .failure(ConnectError(code: .unimplemented, message: nil)))
        }
        return await handler(request, headers)
    }
}

private struct ClientMockResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

private final class ClientMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> ClientMockResponse

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: Handler?
        var count = 0
    }

    private static let state = State()

    static var requestCount: Int {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.count
    }

    static func setHandler(_ newHandler: @escaping Handler) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.handler = newHandler
    }

    static func reset() {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.handler = nil
        state.count = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let activeHandler: Handler? = {
            Self.state.lock.lock()
            defer { Self.state.lock.unlock() }
            Self.state.count += 1
            return Self.state.handler
        }()

        guard let activeHandler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let body = Self.readRequestBody(from: request)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let mock = try activeHandler(self.request, body)
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: mock.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: mock.headers
                ) else {
                    self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !mock.body.isEmpty {
                    self.client?.urlProtocol(self, didLoad: mock.body)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}

    private static func readRequestBody(from request: URLRequest) -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
