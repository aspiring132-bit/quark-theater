import Foundation
import XCTest
@testable import QuarkTheater

@MainActor
final class QuarkClientTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var tokenReply: StubReply {
        StubReply(json: ["status": 2000000, "data": ["members": ["token": "TEST-TOKEN-NOT-A-CREDENTIAL"]]])
    }
    private var ticketReply: StubReply {
        StubReply(json: ["status": 2000000, "message": "ok", "data": ["members": ["service_ticket": "TEST-TICKET"]]])
    }
    private var exchangeReply: StubReply {
        StubReply(json: [:], headers: ["Set-Cookie": "__uid=TEST-UID; Domain=.quark.cn; Path=/; Secure; HttpOnly"])
    }
    private func filesReply(total: Int = 1) -> StubReply {
        StubReply(json: ["status": 200, "code": 0, "data": ["list": [["fid": "f-1", "pdir_fid": "0", "file_name": "电影.2024.MP4", "size": 2048, "updated_at": 1_800_000_000_000, "dir": false]]], "metadata": ["_page": 1, "_count": 1, "_total": total]])
    }
    private func authenticated(diagnostics: Diagnostics? = nil) async throws -> (LiveQuarkClient, QueueTransport, MemoryCredentials, Account) {
        let transport = QueueTransport([tokenReply, ticketReply, exchangeReply, filesReply()])
        let store = MemoryCredentials()
        let client = LiveQuarkClient(transport: transport, credentialStore: store, now: { self.baseDate }, diagnostics: diagnostics)
        let challenge = try await client.beginQRCodeLogin()
        let state = try await client.pollQRCodeLogin(challenge)
        guard case .authenticated(let account) = state else { throw FixtureError.unexpectedState }
        return (client, transport, store, account)
    }
    func testInitializationHasNoNetworkOrStorageSideEffects() async throws {
        let transport = QueueTransport([])
        let store = MemoryCredentials()
        let client = LiveQuarkClient(transport: transport, credentialStore: store)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(store.reads, 0)
        let restored = try await client.restoreSession()
        XCTAssertNil(restored)
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testQRRequestAndWaitingContract() async throws {
        let transport = QueueTransport([tokenReply, StubReply(json: ["status": 50004001])])
        let client = LiveQuarkClient(transport: transport, credentialStore: MemoryCredentials())
        let challenge = try await client.beginQRCodeLogin()
        XCTAssertEqual(challenge.qrURL.host, "su.quark.cn")
        let qr = query(challenge.qrURL)
        XCTAssertEqual(qr["token"], "TEST-TOKEN-NOT-A-CREDENTIAL")
        XCTAssertEqual(qr["uc_biz_str"], "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0")
        let state = try await client.pollQRCodeLogin(challenge)
        guard case .waiting = state else { return XCTFail("Expected a waiting state") }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.path, "/cas/ajax/getTokenForQrcodeLogin")
        XCTAssertEqual(query(try XCTUnwrap(request.url))["client_id"], "532")
        XCTAssertNotNil(UUID(uuidString: query(try XCTUnwrap(request.url))["request_id"] ?? ""))
    }
    func testLocalTimeoutDoesNotPerformAnotherPoll() async throws {
        var time = baseDate
        let transport = QueueTransport([tokenReply])
        let client = LiveQuarkClient(transport: transport, credentialStore: MemoryCredentials(), now: { time })
        let challenge = try await client.beginQRCodeLogin()
        time.addTimeInterval(LiveQuarkClient.localQRCodeTimeout + 1)
        let state = try await client.pollQRCodeLogin(challenge)
        guard case .expired = state else { return XCTFail("Expected local waiting timeout") }
        XCTAssertEqual(transport.requests.count, 1)
    }
    func testCancellingQRInvalidatesChallengeBeforeAnotherPoll() async throws {
        let transport = QueueTransport([tokenReply])
        let client = LiveQuarkClient(transport: transport, credentialStore: MemoryCredentials())
        let challenge = try await client.beginQRCodeLogin()
        client.cancelQRCodeLogin()
        let state = try await client.pollQRCodeLogin(challenge)
        guard case .expired = state else { return XCTFail("Expected canceled challenge to expire") }
        XCTAssertEqual(transport.requests.count, 1)
    }
    func testQRFailureIsNotReportedAsWaiting() async throws {
        let transport = QueueTransport([tokenReply, StubReply(json: ["status": 50004002])])
        let client = LiveQuarkClient(transport: transport, credentialStore: MemoryCredentials())
        let challenge = try await client.beginQRCodeLogin()
        do { _ = try await client.pollQRCodeLogin(challenge); XCTFail("Expected server failure") }
        catch let error as QuarkError {
            guard case .server(let code, _) = error else { return XCTFail("Wrong failure") }
            XCTAssertEqual(code, 50004002)
        }
    }
    func testQRBusinessRejectionEmitsFailedDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticsStore(directoryURL: directory)
        let diagnostics = Diagnostics(store: store)
        let transport = QueueTransport([StubReply(json: ["status": 50004002, "code": 9001])])
        let client = LiveQuarkClient(transport: transport, credentialStore: MemoryCredentials(), diagnostics: diagnostics)

        do { _ = try await client.beginQRCodeLogin(); XCTFail("Expected QR token rejection") }
        catch let error as QuarkError {
            guard case .server(let code, _) = error else { return XCTFail("Wrong failure") }
            XCTAssertEqual(code, 50004002)
        }
        await diagnostics.waitForPendingOperations()
        let records = await store.recent(limit: 10)
        let loginRecords = records.filter { $0.category == .cloud && $0.metadata["endpoint"] == .string(DiagnosticQuarkEndpoint.loginToken.rawValue) }
        XCTAssertTrue(loginRecords.contains { $0.event == .requestFailed && $0.metadata["businessCode"] == .int(9001) })
        XCTAssertFalse(loginRecords.contains { $0.event == .requestCompleted })
    }
    func testAccountBusinessRejectionEmitsFailedDiagnostic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticsStore(directoryURL: directory)
        let diagnostics = Diagnostics(store: store)
        let accountRejected = StubReply(json: ["status": 50004002, "code": 9002], headers: ["Set-Cookie": "__uid=TEST-UID; Domain=.quark.cn; Path=/; Secure; HttpOnly"])
        let transport = QueueTransport([tokenReply, ticketReply, accountRejected])
        let client = LiveQuarkClient(transport: transport, credentialStore: MemoryCredentials(), diagnostics: diagnostics)
        let challenge = try await client.beginQRCodeLogin()

        do { _ = try await client.pollQRCodeLogin(challenge); XCTFail("Expected account exchange rejection") }
        catch let error as QuarkError {
            guard case .server(let code, _) = error else { return XCTFail("Wrong failure") }
            XCTAssertEqual(code, 9002)
        }
        await diagnostics.waitForPendingOperations()
        let records = await store.recent(limit: 20)
        let accountRecords = records.filter { $0.category == .cloud && $0.metadata["endpoint"] == .string(DiagnosticQuarkEndpoint.accountInfo.rawValue) }
        XCTAssertTrue(accountRecords.contains { $0.event == .requestFailed && $0.metadata["businessCode"] == .int(9002) })
        XCTAssertFalse(accountRecords.contains { $0.event == .requestCompleted })
    }
    func testLoginRequiresTicketExchangeAndAuthenticatedListing() async throws {
        let (_, transport, store, account) = try await authenticated()
        XCTAssertNotNil(UUID(uuidString: account.accountId))
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(transport.requests[2].url?.path, "/account/info")
        XCTAssertEqual(query(try XCTUnwrap(transport.requests[2].url))["lw"], "scan")
        XCTAssertEqual(transport.requests[3].value(forHTTPHeaderField: "Cookie"), "__uid=TEST-UID")
        let saved = try JSONDecoder().decode(StoredQuarkSession.self, from: XCTUnwrap(store.data))
        XCTAssertEqual(saved.account.accountId, account.accountId)
        XCTAssertEqual(try saved.cookies().first?.domain, ".quark.cn")
    }
    func testSuccessfulTicketWithoutCookiesCannotAuthenticate() async throws {
        let transport = QueueTransport([tokenReply, ticketReply, StubReply(json: [:])])
        let store = MemoryCredentials()
        let client = LiveQuarkClient(transport: transport, credentialStore: store)
        let challenge = try await client.beginQRCodeLogin()
        do { _ = try await client.pollQRCodeLogin(challenge); XCTFail("Expected missing cookie failure") }
        catch { XCTAssertEqual(error as? QuarkError, .authenticationRequired) }
        XCTAssertNil(store.data)
        XCTAssertEqual(transport.requests.count, 3)
    }
    func testListUsesOneBasedPaginationAndMapsFileFields() async throws {
        let (client, transport, _, _) = try await authenticated()
        transport.replies.append(filesReply(total: 120))
        let result = try await client.listFiles(parentID: "目录 & one", page: 2, pageSize: 50)
        XCTAssertEqual(result.files.first?.fileExtension, "mp4")
        XCTAssertEqual(result.files.first?.modifiedAt, baseDate)
        XCTAssertEqual(result.total, 120)
        XCTAssertTrue(result.hasMore)
        let parameters = query(try XCTUnwrap(transport.requests.last?.url))
        XCTAssertEqual(parameters["pdir_fid"], "目录 & one")
        XCTAssertEqual(parameters["_page"], "2")
        XCTAssertEqual(parameters["_size"], "50")
        XCTAssertEqual(parameters["pr"], "ucpro")
    }
    func testSearchUsesVerifiedQuarkSearchContract() async throws {
        let (client, transport, _, _) = try await authenticated()
        transport.replies.append(filesReply())
        let result = try await client.searchFiles(query: "电影 2024", page: 2, pageSize: 25)
        XCTAssertEqual(result.files.first?.fileId, "f-1")
        let parameters = query(try XCTUnwrap(transport.requests.last?.url))
        XCTAssertEqual(transport.requests.last?.url?.path, "/1/clouddrive/file/search")
        XCTAssertEqual(parameters["q"], "电影 2024")
        XCTAssertEqual(parameters["_page"], "2")
        XCTAssertEqual(parameters["_size"], "25")
        XCTAssertEqual(parameters["_fetch_total"], "1")
        XCTAssertEqual(parameters["_is_hl"], "1")
    }
    func testRestoreReusesAccountNamespaceAfterValidation() async throws {
        let (_, _, store, account) = try await authenticated()
        let transport = QueueTransport([filesReply()])
        let client = LiveQuarkClient(transport: transport, credentialStore: store)
        let restored = try await client.restoreSession()
        XCTAssertEqual(restored?.accountId, account.accountId)
        XCTAssertEqual(transport.requests.count, 1)
    }
    func test403PreservesCredentialsAndDoesNotRetry() async throws {
        let (_, _, store, _) = try await authenticated()
        let transport = QueueTransport([StubReply(json: [:], status: 403)])
        let client = LiveQuarkClient(transport: transport, credentialStore: store)
        do { _ = try await client.restoreSession(); XCTFail("Expected access rejection") }
        catch { XCTAssertEqual(error as? QuarkError, .forbidden) }
        XCTAssertNotNil(store.data)
        XCTAssertEqual(transport.requests.count, 1)
    }
    func test401RemovesInvalidStoredCredentials() async throws {
        let (_, _, store, _) = try await authenticated()
        let client = LiveQuarkClient(transport: QueueTransport([StubReply(json: [:], status: 401)]), credentialStore: store)
        do { _ = try await client.restoreSession(); XCTFail("Expected expired session") }
        catch { XCTAssertEqual(error as? QuarkError, .authenticationRequired) }
        XCTAssertNil(store.data)
    }
    func testMalformedSuccessDoesNotReturnEmptyOrMockList() async throws {
        let (client, transport, _, _) = try await authenticated()
        transport.replies.append(StubReply(json: ["status": 200, "code": 0, "data": [:]]))
        do { _ = try await client.listFiles(parentID: "0", page: 1, pageSize: 50); XCTFail("Expected schema failure") }
        catch let error as QuarkError {
            guard case .invalidResponse = error else { return XCTFail("Wrong failure") }
        }
    }
    func testDownloadIsEphemeralAndMatchesRequestedFile() async throws {
        let (client, transport, store, _) = try await authenticated()
        let before = store.data
        transport.replies.append(StubReply(json: ["status": 200, "code": 0, "data": [["fid": "f-1", "download_url": "https://media.example.invalid/a.mp4?signature=SYNTHETIC"]]]))
        let resource = try await client.playbackResource(fileID: "f-1")
        XCTAssertNil(resource.expiresAt)
        XCTAssertNil(resource.requiredHTTPHeaders["Cookie"])
        XCTAssertEqual(store.data, before)
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: [String]]
        XCTAssertEqual(body?["fids"], ["f-1"])
    }

    func testPlaybackFallbackEmitsCorrelatedRedactedCloudEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticsStore(directoryURL: directory)
        let diagnostics = Diagnostics(store: store)
        let (client, transport, _, _) = try await authenticated(diagnostics: diagnostics)

        transport.replies.append(StubReply(json: ["status": 503, "code": 9001]))
        transport.replies.append(StubReply(json: ["status": 200, "code": 0,
            "data": [["fid": "f-1", "download_url": "https://media.example.invalid/a.mp4"]]]))

        _ = try await client.playbackResource(fileID: "f-1")
        await diagnostics.waitForPendingOperations()
        let records = await store.recent(limit: 10)
        let cloud = records.filter {
            $0.category == .cloud &&
            ($0.metadata["endpoint"] == .string(DiagnosticQuarkEndpoint.filePlay.rawValue) ||
             $0.metadata["endpoint"] == .string(DiagnosticQuarkEndpoint.fileDownload.rawValue))
        }
        XCTAssertTrue(cloud.contains { $0.event == .requestFailed })
        XCTAssertTrue(cloud.contains {
            $0.event == .requestFailed && $0.metadata["businessCode"] == .int(9001)
        })
        XCTAssertTrue(cloud.contains { $0.event == .requestFallback })
        XCTAssertTrue(cloud.contains { $0.event == .requestCompleted })
        let correlations = Set(cloud.compactMap(\.correlationID))
        XCTAssertEqual(correlations.count, 1)
        XCTAssertFalse(cloud.contains { $0.metadata.keys.contains("url") || $0.metadata.keys.contains("fileID") })
    }
    func testCookieScopeRejectsLookalikesAndWrongPaths() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "TEST", .domain: ".quark.cn", .path: "/account", .secure: "TRUE"]))
        XCTAssertTrue(LiveQuarkClient.cookie(cookie, matches: URL(string: "https://pan.quark.cn/account/info")!, at: baseDate))
        XCTAssertFalse(LiveQuarkClient.cookie(cookie, matches: URL(string: "https://evilquark.cn/account")!, at: baseDate))
        XCTAssertFalse(LiveQuarkClient.cookie(cookie, matches: URL(string: "https://pan.quark.cn/accounting")!, at: baseDate))
        XCTAssertFalse(LiveQuarkClient.cookie(cookie, matches: URL(string: "http://pan.quark.cn/account")!, at: baseDate))
    }
    func testMockRequiresExplicitEntryAndNeverResolvesPlayback() async throws {
        let client = MockQuarkClient()
        let restored = try await client.restoreSession()
        XCTAssertNil(restored)
        XCTAssertTrue(client.enterDemo().displayName.contains("MOCK"))
        let page = try await client.listFiles(parentID: "0", page: 1, pageSize: 50)
        XCTAssertTrue(page.files.allSatisfy { $0.name.contains("MOCK") })
        do { _ = try await client.playbackResource(fileID: "mock-video"); XCTFail("Expected mock-only failure") }
        catch { XCTAssertEqual(error as? QuarkError, .mockOnly) }
    }
    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private enum FixtureError: Error { case exhausted, unexpectedState }
private struct StubReply {
    let json: [String: Any]
    var status: Int = 200
    var headers: [String: String] = [:]
}
@MainActor
private final class QueueTransport: QuarkHTTPTransport {
    var replies: [StubReply]
    var requests: [URLRequest] = []
    init(_ replies: [StubReply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty, let url = request.url else { throw FixtureError.exhausted }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (try JSONSerialization.data(withJSONObject: reply.json), response)
    }
}
@MainActor
private final class MemoryCredentials: CredentialStore {
    var data: Data?
    var reads = 0
    func load() throws -> Data? { reads += 1; return data }
    func save(_ data: Data) throws { self.data = data }
    func delete() throws { data = nil }
}
