import XCTest
@testable import QuarkTheater

@MainActor
final class MultiSourceSyncTests: XCTestCase {
    final class MockSourceAdapter: StorageSourceAdapter {
        let sourceID: String
        let sourceType: StorageSourceType
        let files: [CloudFile]
        var isAvailable: Bool { true }

        init(sourceID: String, sourceType: StorageSourceType, files: [CloudFile]) {
            self.sourceID = sourceID
            self.sourceType = sourceType
            self.files = files
        }

        func testConnection() async throws -> SourceConnectionStatus { .connected }

        func listFiles(folderID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
            CloudFilePage(files: files, page: page, pageSize: pageSize, total: files.count)
        }

        func playbackResource(fileID: String) async throws -> PlaybackResource {
            PlaybackResource(fileID: fileID, url: URL(string: "https://example.com/stream/\(fileID)")!, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
        }
    }

    func testScannerScansAdapterAcrossMultipleRoots() async throws {
        let files1 = [
            CloudFile(fileId: "f1", parentId: "0", name: "Inception.2010.mkv", size: 1000, fileExtension: "mkv", modifiedAt: nil, isDirectory: false)
        ]
        let adapter = MockSourceAdapter(sourceID: "mock-1", sourceType: .webdav, files: files1)

        let scanner = MediaLibraryScanner()
        let candidates = try await scanner.scan(adapter: adapter, roots: [MediaScanRoot(id: "0", name: "影视")])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.file.fileId, "f1")
        XCTAssertEqual(candidates.first?.parsedName.title, "Inception")
    }

    func testMultiSourceCandidateAggregation() async throws {
        let s1 = StorageSource(id: "src-1", type: .quark, displayName: "夸克源", boundFolderIDs: ["q_root"])
        let s2 = StorageSource(id: "src-2", type: .webdav, displayName: "NAS 源", boundFolderIDs: ["/Movies"])

        XCTAssertNotEqual(s1.id, s2.id)
        XCTAssertNotEqual(s1.type, s2.type)
        XCTAssertEqual(s1.boundFolderIDs, ["q_root"])
        XCTAssertEqual(s2.boundFolderIDs, ["/Movies"])
    }

    // MARK: - Backward-Compatible Decoding Tests
    func testLegacyQuarkDataDecodingDefaults() throws {
        // 1. MediaItem legacy JSON without sourceId / sourceType
        let legacyItemJSON = """
        {
            "id": "item-legacy-1",
            "fileId": "file-legacy-1",
            "mediaType": "movie",
            "title": "Interstellar",
            "year": 2014,
            "tmdbId": 157336,
            "matchConfidence": 0.95
        }
        """
        let decodedItem = try JSONDecoder().decode(MediaItem.self, from: Data(legacyItemJSON.utf8))
        XCTAssertEqual(decodedItem.sourceType, .quark)
        XCTAssertEqual(decodedItem.sourceId, "quark-default")
        XCTAssertEqual(decodedItem.title, "Interstellar")

        // 2. CloudFile legacy JSON without sourceID
        let legacyFileJSON = """
        {
            "fileId": "file-legacy-1",
            "parentId": "0",
            "name": "Interstellar.2014.mkv",
            "size": 1024,
            "fileExtension": "mkv",
            "isDirectory": false
        }
        """
        let decodedFile = try JSONDecoder().decode(CloudFile.self, from: Data(legacyFileJSON.utf8))
        XCTAssertNil(decodedFile.sourceID)
        XCTAssertEqual(decodedFile.fileId, "file-legacy-1")
    }

    // MARK: - Multi-Source End-to-End Sync Tests
    final class MockSourceRepositoryClient: QuarkClient {
        var scannedFolderIDs: [String] = []

        func restoreSession() async throws -> Account? {
            Account(accountId: "quark-account-1", displayName: "Test User", authenticationState: .authenticated)
        }
        func beginQRCodeLogin() async throws -> QRLoginChallenge {
            QRLoginChallenge(token: "1", qrURL: URL(string: "https://example.com")!, createdAt: Date())
        }
        func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { .waiting }
        func cancelQRCodeLogin() {}

        func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
            scannedFolderIDs.append(parentID)
            let file = CloudFile(
                fileId: "quark-vid-1",
                parentId: parentID,
                name: "QuarkShow.S01E01.mp4",
                size: 1000,
                fileExtension: "mp4",
                modifiedAt: nil,
                isDirectory: false
            )
            return CloudFilePage(files: [file], page: 1, pageSize: 1, total: 1)
        }

        func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
            CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
        }
        func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
            PlaybackResource(fileID: fileID, url: URL(string: "https://pan.quark.cn/v2/play/\(fileID)")!, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
        }
        func logout() async throws {}
    }

    final class ControllableMockSourceAdapter: StorageSourceAdapter {
        let sourceID: String
        let sourceType: StorageSourceType
        let filesByFolder: [String: [CloudFile]]
        var isAvailable: Bool
        var listFilesCallCount = 0

        init(sourceID: String, sourceType: StorageSourceType, filesByFolder: [String: [CloudFile]], isAvailable: Bool = true) {
            self.sourceID = sourceID
            self.sourceType = sourceType
            self.filesByFolder = filesByFolder
            self.isAvailable = isAvailable
        }

        func testConnection() async throws -> SourceConnectionStatus {
            isAvailable ? .connected : .blocked(reason: "Unavailable")
        }

        func listFiles(folderID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
            listFilesCallCount += 1
            let files = filesByFolder[folderID] ?? []
            return CloudFilePage(files: files, page: page, pageSize: pageSize, total: files.count)
        }

        func playbackResource(fileID: String) async throws -> PlaybackResource {
            PlaybackResource(fileID: fileID, url: URL(string: "https://\(sourceID).local/play/\(fileID)")!, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
        }
    }

    func testSyncScansEnabledSourcesAndExcludesBlockedSMBAndAliyun() async throws {
        let tempRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sync_sources_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempRepoURL) }
        let sourceRepo = SourceRepository(storageURL: tempRepoURL)

        // 1. Quark source (enabled)
        let quarkSource = StorageSource(id: "quark-account-1", type: .quark, displayName: "夸克主号", boundFolderIDs: ["q-folder-1"], isEnabled: true)
        // 2. WebDAV source (enabled)
        let webdavSource = StorageSource(id: "webdav-active", type: .webdav, displayName: "有效 WebDAV", endpointURL: "https://nas.local:5005", boundFolderIDs: ["/Movies"], isEnabled: true)
        // 3. WebDAV source (disabled)
        let disabledWebDAV = StorageSource(id: "webdav-disabled", type: .webdav, displayName: "已停用 WebDAV", endpointURL: "https://nas-off.local:5005", boundFolderIDs: ["/TV"], isEnabled: false)
        // 4. SMB source (unsupported / blocked)
        let smbSource = StorageSource(id: "smb-1", type: .smb, displayName: "家庭 SMB", endpointURL: "smb://192.168.1.10", status: .blocked(reason: "tvOS 需要 libsmb2 支持"), boundFolderIDs: ["smb-share"], isEnabled: true)
        // 5. Aliyun source (unsupported / blocked)
        let aliyunSource = StorageSource(id: "aliyun-1", type: .aliyun, displayName: "阿里网盘", status: .blocked(reason: "缺少 OpenAPI 凭据"), boundFolderIDs: ["ali-folder"], isEnabled: true)

        try sourceRepo.saveSource(quarkSource)
        try sourceRepo.saveSource(webdavSource)
        try sourceRepo.saveSource(disabledWebDAV)
        try sourceRepo.saveSource(smbSource)
        try sourceRepo.saveSource(aliyunSource)

        let webdavFiles = [
            CloudFile(fileId: "dav-movie-1", parentId: "/Movies", name: "Inception.2010.mp4", size: 5000, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        ]
        let webdavAdapter = ControllableMockSourceAdapter(sourceID: "webdav-active", sourceType: .webdav, filesByFolder: ["/Movies": webdavFiles])
        sourceRepo.registerCustomAdapter(webdavAdapter, for: "webdav-active")

        let disabledAdapter = ControllableMockSourceAdapter(sourceID: "webdav-disabled", sourceType: .webdav, filesByFolder: [:])
        sourceRepo.registerCustomAdapter(disabledAdapter, for: "webdav-disabled")

        let client = MockSourceRepositoryClient()
        let tempCatalogURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_catalog_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempCatalogURL) }
        let catalog = try MediaCatalogRepository(url: tempCatalogURL)

        let syncService = MediaLibrarySyncService(
            client: client,
            accountID: "quark-account-1",
            catalog: catalog,
            tokenStore: TMDBCredentialStore(),
            diagnostics: Diagnostics(),
            sourceRepository: sourceRepo
        )

        let (candidates, result) = try await syncService.sync(boundFolderIDs: ["q-folder-1"]) { _ in }

        // Both enabled sources were scanned
        XCTAssertTrue(client.scannedFolderIDs.contains("q-folder-1"))
        XCTAssertEqual(webdavAdapter.listFilesCallCount, 1)

        // Disabled and blocked sources were NOT scanned
        XCTAssertEqual(disabledAdapter.listFilesCallCount, 0)

        // Candidates contain files from both operational sources
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.contains(where: { $0.file.sourceID == "quark-account-1" }))
        XCTAssertTrue(candidates.contains(where: { $0.file.sourceID == "webdav-active" }))
        XCTAssertEqual(result.candidateCount, 2)
    }

    func testTwoSourcesWithCollidingFileIDsRemainIsolated() async throws {
        let tempRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_colliding_sources_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempRepoURL) }
        let sourceRepo = SourceRepository(storageURL: tempRepoURL)

        // Two WebDAV sources
        let s1 = StorageSource(id: "source-1", type: .webdav, displayName: "源 1", endpointURL: "https://nas1.local", boundFolderIDs: ["/Media"], isEnabled: true)
        let s2 = StorageSource(id: "source-2", type: .webdav, displayName: "源 2", endpointURL: "https://nas2.local", boundFolderIDs: ["/Media"], isEnabled: true)
        try sourceRepo.saveSource(s1)
        try sourceRepo.saveSource(s2)

        // Both sources have a video with the EXACT SAME fileId: "colliding-id"
        let collidingFileID = "colliding-id"
        let file1 = CloudFile(fileId: collidingFileID, parentId: "/Media", name: "Gladiator.2000.mp4", size: 3000, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        let file2 = CloudFile(fileId: collidingFileID, parentId: "/Media", name: "Gladiator.II.2024.mp4", size: 7000, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)

        let adapter1 = ControllableMockSourceAdapter(sourceID: "source-1", sourceType: .webdav, filesByFolder: ["/Media": [file1]])
        let adapter2 = ControllableMockSourceAdapter(sourceID: "source-2", sourceType: .webdav, filesByFolder: ["/Media": [file2]])
        sourceRepo.registerCustomAdapter(adapter1, for: "source-1")
        sourceRepo.registerCustomAdapter(adapter2, for: "source-2")

        let client = MockSourceRepositoryClient()
        let tempCatalogURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_colliding_catalog_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempCatalogURL) }
        let catalog = try MediaCatalogRepository(url: tempCatalogURL)

        let syncService = MediaLibrarySyncService(
            client: client,
            accountID: "user-root",
            catalog: catalog,
            tokenStore: TMDBCredentialStore(),
            diagnostics: Diagnostics(),
            sourceRepository: sourceRepo
        )

        let (candidates, _) = try await syncService.sync(boundFolderIDs: []) { _ in }

        // Both sources scanned: 2 candidates found
        XCTAssertEqual(candidates.count, 2)

        // Candidate 1 belongs to source-1, Candidate 2 belongs to source-2
        let c1 = try XCTUnwrap(candidates.first(where: { $0.file.sourceID == "source-1" }))
        let c2 = try XCTUnwrap(candidates.first(where: { $0.file.sourceID == "source-2" }))

        XCTAssertEqual(c1.file.fileId, collidingFileID)
        XCTAssertEqual(c2.file.fileId, collidingFileID)
        XCTAssertEqual(c1.parsedName.title, "Gladiator")
        XCTAssertEqual(c2.parsedName.title, "Gladiator II")

        // Persist confirmed items in catalog under their respective source IDs
        let item1 = MediaItem(
            id: collidingFileID,
            fileId: collidingFileID,
            mediaType: .movie,
            title: "Gladiator",
            year: 2000,
            tmdbId: 98,
            matchConfidence: 0.99,
            sourceType: .webdav,
            sourceId: "source-1"
        )
        let item2 = MediaItem(
            id: collidingFileID,
            fileId: collidingFileID,
            mediaType: .movie,
            title: "Gladiator II",
            year: 2024,
            tmdbId: 558449,
            matchConfidence: 0.99,
            sourceType: .webdav,
            sourceId: "source-2"
        )
        try catalog.confirm(item1, accountID: "source-1")
        try catalog.confirm(item2, accountID: "source-2")

        // Isolated retrieval: source-1's item is NOT overwritten by source-2's item
        let confirmed1 = try catalog.confirmed(accountID: "source-1")
        let confirmed2 = try catalog.confirmed(accountID: "source-2")

        XCTAssertEqual(confirmed1.count, 1)
        XCTAssertEqual(confirmed1.first?.fileId, collidingFileID)
        XCTAssertEqual(confirmed1.first?.sourceId, "source-1")
        XCTAssertEqual(confirmed1.first?.tmdbId, 98)

        XCTAssertEqual(confirmed2.count, 1)
        XCTAssertEqual(confirmed2.first?.fileId, collidingFileID)
        XCTAssertEqual(confirmed2.first?.sourceId, "source-2")
        XCTAssertEqual(confirmed2.first?.tmdbId, 558449)
    }
}
