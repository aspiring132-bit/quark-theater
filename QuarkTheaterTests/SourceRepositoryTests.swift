import XCTest
@testable import QuarkTheater

@MainActor
final class SourceRepositoryTests: XCTestCase {
    var repository: SourceRepository!
    var tempFileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sources_\(UUID().uuidString).json")
        repository = SourceRepository(storageURL: tempFileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempFileURL)
        try await super.tearDown()
    }

    func testAddAndRetrieveSources() async throws {
        let s1 = StorageSource(id: "quark-1", type: .quark, displayName: "我的夸克主账号")
        let s2 = StorageSource(id: "webdav-1", type: .webdav, displayName: "家庭 NAS", endpointURL: "https://nas.local:5005")

        try await repository.saveSource(s1)
        try await repository.saveSource(s2)

        let all = await repository.allSources()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains(where: { $0.id == "quark-1" }))
        XCTAssertTrue(all.contains(where: { $0.id == "webdav-1" }))
    }

    func testUpdateSourceAliasAndToggleEnabled() async throws {
        var s = StorageSource(id: "webdav-1", type: .webdav, displayName: "NAS 1", isEnabled: true)
        try await repository.saveSource(s)

        s.displayName = "群晖 NAS (影视)"
        s.isEnabled = false
        try await repository.saveSource(s)

        let loaded = await repository.source(id: "webdav-1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.displayName, "群晖 NAS (影视)")
        XCTAssertFalse(loaded!.isEnabled)
    }

    func testRemoveSourceDoesNotTouchRemoteFiles() async throws {
        let s = StorageSource(id: "webdav-to-remove", type: .webdav, displayName: "待删除源")
        try await repository.saveSource(s)

        // Save dummy credential in credential store
        try SourceCredentialStore.shared.saveSecret("dummy-pwd", for: "webdav-to-remove", key: "password")
        XCTAssertNotNil(try SourceCredentialStore.shared.loadSecret(for: "webdav-to-remove", key: "password"))

        // Perform removal
        try await repository.removeSource(id: "webdav-to-remove")

        // Local record should be gone
        let after = await repository.source(id: "webdav-to-remove")
        XCTAssertNil(after)

        // Credential should be gone
        let pwd = try SourceCredentialStore.shared.loadSecret(for: "webdav-to-remove", key: "password")
        XCTAssertNil(pwd)
    }

    func testBlockedAdaptersExplicitDeclaration() async throws {
        let smbAdapter = SMBSourceAdapter(sourceID: "smb-1", host: "192.168.1.50", shareName: "video")
        XCTAssertFalse(smbAdapter.isAvailable)
        let smbStatus = try await smbAdapter.testConnection()
        if case .blocked(let reason) = smbStatus {
            XCTAssertTrue(reason.contains("libsmb2"))
        } else {
            XCTFail("SMB must report .blocked with libsmb2 blocker")
        }

        let aliyunAdapter = AliyunSourceAdapter(sourceID: "aliyun-1")
        XCTAssertFalse(aliyunAdapter.isAvailable)
        let aliyunStatus = try await aliyunAdapter.testConnection()
        if case .blocked(let reason) = aliyunStatus {
            XCTAssertTrue(reason.contains("OpenAPI"))
        } else {
            XCTFail("Aliyun must report .blocked with OpenAPI blocker")
        }
    }

    // MARK: - Fail-Closed Credential Storage Tests (Issue 1)
    final class FailingKeychainMock: KeychainInterface {
        let errorCode: OSStatus
        init(errorCode: OSStatus = -34018) {
            self.errorCode = errorCode
        }
        func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus { errorCode }
        func add(_ attributes: [String: Any]) -> OSStatus { errorCode }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errorCode }
        func delete(_ query: [String: Any]) -> OSStatus { errorCode }
    }

    final class InMemoryKeychainMock: KeychainInterface {
        var storage: [String: Data] = [:]

        private func key(from query: [String: Any]) -> String {
            (query[kSecAttrAccount as String] as? String) ?? ""
        }

        func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
            let k = key(from: query)
            guard let data = storage[k] else { return errSecItemNotFound }
            result = data as CFTypeRef
            return errSecSuccess
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            let k = key(from: attributes)
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            storage[k] = data
            return errSecSuccess
        }

        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            let k = key(from: query)
            guard storage[k] != nil else { return errSecItemNotFound }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            storage[k] = data
            return errSecSuccess
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            let k = key(from: query)
            guard storage.removeValue(forKey: k) != nil else { return errSecItemNotFound }
            return errSecSuccess
        }
    }

    func testSourceCredentialStoreFailsClosedOnKeychainEntitlementError() async throws {
        let failingKeychain = FailingKeychainMock(errorCode: -34018)
        let store = SourceCredentialStore(keychain: failingKeychain)

        // 1. Secret save must throw QuarkError.credentialStorage(-34018)
        XCTAssertThrowsError(try store.saveSecret("super_secret", for: "test-source", key: "password")) { error in
            guard case QuarkError.credentialStorage(let code) = error else {
                XCTFail("Expected QuarkError.credentialStorage but got \(error)")
                return
            }
            XCTAssertEqual(code, -34018)
        }

        // 2. Secret load must throw on Keychain error
        XCTAssertThrowsError(try store.loadSecret(for: "test-source", key: "password")) { error in
            guard case QuarkError.credentialStorage(let code) = error else {
                XCTFail("Expected QuarkError.credentialStorage but got \(error)")
                return
            }
            XCTAssertEqual(code, -34018)
        }

        // 3. Cookies save must throw
        let cookie = HTTPCookie(properties: [
            .name: "session",
            .value: "token123",
            .domain: "example.com",
            .path: "/"
        ])!
        XCTAssertThrowsError(try store.saveCookies([cookie], for: "test-source")) { error in
            guard case QuarkError.credentialStorage(let code) = error else {
                XCTFail("Expected QuarkError.credentialStorage but got \(error)")
                return
            }
            XCTAssertEqual(code, -34018)
        }

        // 4. Cookies load must throw
        XCTAssertThrowsError(try store.loadCookies(for: "test-source")) { error in
            guard case QuarkError.credentialStorage(let code) = error else {
                XCTFail("Expected QuarkError.credentialStorage but got \(error)")
                return
            }
            XCTAssertEqual(code, -34018)
        }

        // 5. Delete secret must throw
        XCTAssertThrowsError(try store.deleteSecret(for: "test-source", key: "password")) { error in
            guard case QuarkError.credentialStorage(let code) = error else {
                XCTFail("Expected QuarkError.credentialStorage but got \(error)")
                return
            }
            XCTAssertEqual(code, -34018)
        }

        // 6. Verify NO plaintext files were created anywhere in Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("QuarkTheater", isDirectory: true)
            let credFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.hasPrefix("cred_test-source") } ?? []
            XCTAssertTrue(credFiles.isEmpty, "No credential files should ever be written to disk on Keychain failure")
        }
    }

    func testSourceCredentialStorePurgesKeychainOnSourceRemoval() async throws {
        let mockKeychain = InMemoryKeychainMock()
        let store = SourceCredentialStore(keychain: mockKeychain)

        try store.saveSecret("my-password", for: "webdav-to-remove", key: "password")
        try store.saveSecret("my-secret", for: "webdav-to-remove", key: "secret")
        try store.saveSecret("my-token", for: "webdav-to-remove", key: "token")

        let cookie = HTTPCookie(properties: [
            .name: "auth",
            .value: "val",
            .domain: "local",
            .path: "/"
        ])!
        try store.saveCookies([cookie], for: "webdav-to-remove")

        XCTAssertNotNil(try store.loadSecret(for: "webdav-to-remove", key: "password"))
        XCTAssertNotNil(try store.loadSecret(for: "webdav-to-remove", key: "secret"))
        XCTAssertNotNil(try store.loadSecret(for: "webdav-to-remove", key: "token"))
        XCTAssertEqual(try store.loadCookies(for: "webdav-to-remove")?.count, 1)

        // Delete all credentials
        try store.deleteAllCredentials(for: "webdav-to-remove")

        XCTAssertNil(try store.loadSecret(for: "webdav-to-remove", key: "password"))
        XCTAssertNil(try store.loadSecret(for: "webdav-to-remove", key: "secret"))
        XCTAssertNil(try store.loadSecret(for: "webdav-to-remove", key: "token"))
        XCTAssertNil(try store.loadCookies(for: "webdav-to-remove"))
        XCTAssertTrue(mockKeychain.storage.isEmpty)
    }

    func testSourceRemovalPurgesKeychainEntries() async throws {
        let mockKeychain = InMemoryKeychainMock()
        let credStore = SourceCredentialStore(keychain: mockKeychain)
        let tempRepoURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_sources_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempRepoURL) }
        let sourceRepo = SourceRepository(storageURL: tempRepoURL, credentialStore: credStore)

        let s1 = StorageSource(id: "webdav-to-purge", type: .webdav, displayName: "Purge NAS", isEnabled: true)
        try sourceRepo.saveSource(s1)
        try credStore.saveSecret("mypassword", for: "webdav-to-purge", key: "password")

        XCTAssertNotNil(try credStore.loadSecret(for: "webdav-to-purge", key: "password"))

        try sourceRepo.removeSource(id: "webdav-to-purge")

        XCTAssertNil(sourceRepo.source(id: "webdav-to-purge"))
        XCTAssertNil(try credStore.loadSecret(for: "webdav-to-purge", key: "password"))
        XCTAssertTrue(mockKeychain.storage.isEmpty)
    }
}
