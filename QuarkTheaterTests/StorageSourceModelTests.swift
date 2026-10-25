import XCTest
@testable import QuarkTheater

final class StorageSourceModelTests: XCTestCase {
    func testStorageSourceTypePlatformSupport() {
        XCTAssertTrue(StorageSourceType.quark.isSupportedOnCurrentPlatform)
        XCTAssertTrue(StorageSourceType.webdav.isSupportedOnCurrentPlatform)
        XCTAssertFalse(StorageSourceType.smb.isSupportedOnCurrentPlatform)
        XCTAssertFalse(StorageSourceType.aliyun.isSupportedOnCurrentPlatform)

        XCTAssertNotNil(StorageSourceType.smb.platformSupportNote)
        XCTAssertTrue(StorageSourceType.smb.platformSupportNote?.contains("libsmb2") == true)
        XCTAssertNotNil(StorageSourceType.aliyun.platformSupportNote)
    }

    func testSourceConnectionStatusCodableRoundtrip() throws {
        let statuses: [SourceConnectionStatus] = [
            .connected,
            .scanning,
            .needsReauth,
            .unreachable(reason: "Host unreachable at 192.168.1.100"),
            .configError(reason: "Invalid credentials"),
            .rateLimited(retryAfter: 30),
            .blocked(reason: "SMB requires libsmb2 on tvOS")
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in statuses {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(SourceConnectionStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func testStorageSourceCodableWithoutSensitiveCredentials() throws {
        let source = StorageSource(
            id: "source-webdav-1",
            type: .webdav,
            displayName: "Home NAS WebDAV",
            accountHint: "admin",
            endpointURL: "https://nas.local:5005/dav",
            username: "admin",
            status: .connected,
            boundFolderIDs: ["/Movies", "/TVShows"],
            lastScanAt: Date(timeIntervalSince1970: 1700000000),
            lastErrorSummary: nil,
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1690000000)
        )

        let data = try JSONEncoder().encode(source)
        let jsonString = String(decoding: data, as: UTF8.self)

        // Sensitive fields must never be serialized
        XCTAssertFalse(jsonString.contains("password"))
        XCTAssertFalse(jsonString.contains("token"))
        XCTAssertFalse(jsonString.contains("cookie"))

        let decoded = try JSONDecoder().decode(StorageSource.self, from: data)
        XCTAssertEqual(decoded.id, source.id)
        XCTAssertEqual(decoded.type, .webdav)
        XCTAssertEqual(decoded.displayName, "Home NAS WebDAV")
        XCTAssertEqual(decoded.accountHint, "admin")
        XCTAssertEqual(decoded.endpointURL, "https://nas.local:5005/dav")
        XCTAssertEqual(decoded.boundFolderIDs, ["/Movies", "/TVShows"])
        XCTAssertEqual(decoded.status, .connected)
        XCTAssertTrue(decoded.isEnabled)
    }

    func testSourceEquality() {
        let date = Date()
        let s1 = StorageSource(id: "s1", type: .quark, displayName: "Quark Main", createdAt: date)
        let s2 = StorageSource(id: "s1", type: .quark, displayName: "Quark Main", createdAt: date)
        let s3 = StorageSource(id: "s2", type: .quark, displayName: "Quark Other", createdAt: date)

        XCTAssertEqual(s1, s2)
        XCTAssertNotEqual(s1, s3)
    }
}
