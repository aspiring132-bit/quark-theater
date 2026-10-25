import XCTest
@testable import QuarkTheater

@MainActor
final class PlaybackRoutingTests: XCTestCase {
    func testWebDAVPlaybackRoutingGeneratesValidResource() async throws {
        let endpoint = URL(string: "https://nas.local:5005/dav")!
        let adapter = WebDAVSourceAdapter(sourceID: "webdav-test", endpointURL: endpoint, username: "admin")

        // Save password
        try SourceCredentialStore.shared.saveSecret("pwd123", for: "webdav-test", key: "password")

        let resource = try await adapter.playbackResource(fileID: "/dav/Movies/Film.mkv")

        XCTAssertEqual(resource.fileID, "/dav/Movies/Film.mkv")
        XCTAssertEqual(resource.url.scheme, "https")
        XCTAssertEqual(resource.url.host, "nas.local")
        XCTAssertEqual(resource.url.port, 5005)
        XCTAssertNotNil(resource.requiredHTTPHeaders["Authorization"])
        XCTAssertTrue(resource.requiredHTTPHeaders["Authorization"]?.starts(with: "Basic ") == true)
    }

    func testQuarkPlaybackRoutingDelegatesToClient() async throws {
        final class TestQuarkClient: QuarkClient {
            func restoreSession() async throws -> Account? { nil }
            func beginQRCodeLogin() async throws -> QRLoginChallenge {
                QRLoginChallenge(token: "1", qrURL: URL(string: "https://example.com")!, createdAt: Date())
            }
            func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { .waiting }
            func cancelQRCodeLogin() {}
            func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
                CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
            }
            func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
                CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
            }
            func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
                PlaybackResource(fileID: fileID, url: URL(string: "https://pan.quark.cn/v2/play/\(fileID)")!, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
            }
            func logout() async throws {}
        }

        let client = TestQuarkClient()
        let adapter = QuarkSourceAdapter(sourceID: "quark-test", client: client)

        let resource = try await adapter.playbackResource(fileID: "file-xyz")
        XCTAssertEqual(resource.fileID, "file-xyz")
        XCTAssertTrue(resource.url.absoluteString.contains("pan.quark.cn"))
    }

    func testPlaybackRoutingSelectsExactSourceWhenFileIDsCollide() async throws {
        final class TestQuarkClient: QuarkClient {
            func restoreSession() async throws -> Account? { nil }
            func beginQRCodeLogin() async throws -> QRLoginChallenge {
                QRLoginChallenge(token: "1", qrURL: URL(string: "https://example.com")!, createdAt: Date())
            }
            func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { .waiting }
            func cancelQRCodeLogin() {}
            func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
                CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
            }
            func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
                CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
            }
            func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
                PlaybackResource(fileID: fileID, url: URL(string: "https://pan.quark.cn/v2/play/\(fileID)")!, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
            }
            func logout() async throws {}
        }

        let tempRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_playback_sources_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempRepoURL) }
        let sourceRepo = SourceRepository(storageURL: tempRepoURL)

        let s1 = StorageSource(id: "webdav-source-1", type: .webdav, displayName: "NAS 1", endpointURL: "https://nas1.local:5005/dav", isEnabled: true)
        let s2 = StorageSource(id: "webdav-source-2", type: .webdav, displayName: "NAS 2", endpointURL: "https://nas2.local:5006/dav", isEnabled: true)
        try sourceRepo.saveSource(s1)
        try sourceRepo.saveSource(s2)

        let client = TestQuarkClient()
        let tempHistoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_history_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempHistoryURL) }
        let history = try HistoryRepository(url: tempHistoryURL)
        let diag = Diagnostics()

        // Two files from different sources with the EXACT SAME colliding fileId
        let collidingFileID = "/Movies/SharedMovie.mkv"
        let fileFromSource1 = CloudFile(
            fileId: collidingFileID,
            parentId: "/Movies",
            name: "SharedMovie.mkv",
            size: 5000,
            fileExtension: "mkv",
            modifiedAt: nil,
            isDirectory: false,
            sourceID: "webdav-source-1"
        )
        let fileFromSource2 = CloudFile(
            fileId: collidingFileID,
            parentId: "/Movies",
            name: "SharedMovie.mkv",
            size: 8000,
            fileExtension: "mkv",
            modifiedAt: nil,
            isDirectory: false,
            sourceID: "webdav-source-2"
        )

        // Coordinator 1 playing file from Source 1
        let coordinator1 = PlaybackCoordinator(
            client: client,
            accountID: "user-1",
            file: fileFromSource1,
            history: history,
            diagnostics: diag,
            sourceRepository: sourceRepo
        )
        await coordinator1.start()

        // URL must be from nas1 (Source 1), NOT nas2!
        XCTAssertEqual(coordinator1.ksPlayerURL?.host, "nas1.local")
        XCTAssertEqual(coordinator1.ksPlayerURL?.port, 5005)
        XCTAssertTrue(coordinator1.ksPlayerURL?.path.contains("SharedMovie.mkv") == true)
        coordinator1.stop()

        // Coordinator 2 playing file from Source 2 (with colliding fileId)
        let coordinator2 = PlaybackCoordinator(
            client: client,
            accountID: "user-1",
            file: fileFromSource2,
            history: history,
            diagnostics: diag,
            sourceRepository: sourceRepo
        )
        await coordinator2.start()

        // URL must be from nas2 (Source 2), NOT nas1!
        XCTAssertEqual(coordinator2.ksPlayerURL?.host, "nas2.local")
        XCTAssertEqual(coordinator2.ksPlayerURL?.port, 5006)
        XCTAssertTrue(coordinator2.ksPlayerURL?.path.contains("SharedMovie.mkv") == true)
        coordinator2.stop()
    }

    func testLegacyQuarkPlaybackFallbackWhenSourceIDMissingOrQuark() async throws {
        final class TestQuarkClient: QuarkClient {
            var didCallQuarkPlayback = false
            func restoreSession() async throws -> Account? { nil }
            func beginQRCodeLogin() async throws -> QRLoginChallenge {
                QRLoginChallenge(token: "1", qrURL: URL(string: "https://example.com")!, createdAt: Date())
            }
            func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { .waiting }
            func cancelQRCodeLogin() {}
            func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
                CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
            }
            func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
                CloudFilePage(files: [], page: 1, pageSize: 1, total: 0)
            }
            func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
                didCallQuarkPlayback = true
                return PlaybackResource(fileID: fileID, url: URL(string: "https://pan.quark.cn/v2/play/\(fileID)")!, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
            }
            func logout() async throws {}
        }

        let tempRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_playback_sources_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempRepoURL) }
        let sourceRepo = SourceRepository(storageURL: tempRepoURL)

        // Even with WebDAV sources configured, a legacy Quark file must fall back to Quark client
        let s1 = StorageSource(id: "webdav-first", type: .webdav, displayName: "First WebDAV", endpointURL: "https://first-nas.local:5005", isEnabled: true)
        try sourceRepo.saveSource(s1)

        let client = TestQuarkClient()
        let tempHistoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_history_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempHistoryURL) }
        let history = try HistoryRepository(url: tempHistoryURL)
        let diag = Diagnostics()

        // Legacy file with sourceID = nil and path-like fileId
        let legacyFile = CloudFile(
            fileId: "/legacy/quark/video.mp4",
            parentId: "0",
            name: "video.mp4",
            size: 1000,
            fileExtension: "mp4",
            modifiedAt: nil,
            isDirectory: false,
            sourceID: nil
        )

        let coordinator = PlaybackCoordinator(
            client: client,
            accountID: "user-1",
            file: legacyFile,
            history: history,
            diagnostics: diag,
            sourceRepository: sourceRepo
        )
        await coordinator.start()

        XCTAssertTrue(client.didCallQuarkPlayback)
        XCTAssertEqual(coordinator.ksPlayerURL?.host, "pan.quark.cn")
        coordinator.stop()
    }
}
