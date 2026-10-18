import Foundation
import os

/// Native adapter for the pinned MIT QuarkPan contracts. See API-ADAPTER.md.
@MainActor
final class LiveQuarkClient: QuarkClient {
    private static let logger = Logger(subsystem: "org.quarktheater.app", category: "QuarkClient")
    private let transport: any QuarkHTTPTransport
    private let credentialStore: any CredentialStore
    private let diagnostics: Diagnostics?
    private let now: () -> Date
    private var cookies: [HTTPCookie] = []
    private var account: Account?
    private var activeChallenge: QRLoginChallenge?
    private var sessionGeneration = 0
    private static let api = "https://drive-pc.quark.cn/1/clouddrive"
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
    private static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    // A local waiting limit, not an asserted server QR validity period.
    static let localQRCodeTimeout: TimeInterval = 300

    convenience init(diagnostics: Diagnostics? = nil) throws {
        self.init(transport: URLSessionQuarkTransport(), credentialStore: KeychainCredentialStore(), diagnostics: diagnostics)
    }

    init(transport: any QuarkHTTPTransport, credentialStore: any CredentialStore,
         now: @escaping () -> Date = Date.init, diagnostics: Diagnostics? = nil) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.now = now
        self.diagnostics = diagnostics
    }

    func restoreSession() async throws -> Account? {
        var candidateCookies: [HTTPCookie] = []
        var candidateAccount: Account? = nil

        #if targetEnvironment(simulator)
        let localPath = "/Users/wangbin/.quark_theater_session.json"
        if FileManager.default.fileExists(atPath: localPath),
           let raw = try? Data(contentsOf: URL(fileURLWithPath: localPath)),
           let list = try? JSONDecoder().decode([StoredCookie].self, from: raw) {
            candidateCookies = list.compactMap { $0.toHTTPCookie() }
            candidateAccount = Account(accountId: "quark-local-account", displayName: "夸克账号", authenticationState: .authenticated)
            Self.logger.info("📱 [Simulator] loaded local session cookies")
        }
        #endif

        if candidateCookies.isEmpty, let data = try credentialStore.load() {
            if let stored = try? JSONDecoder().decode(StoredQuarkSession.self, from: data) {
                candidateCookies = (try? stored.cookies()) ?? []
                candidateAccount = stored.account
                Self.logger.info("🔐 loaded session from Keychain")
            }
        }

        guard !candidateCookies.isEmpty, let acc = candidateAccount else {
            Self.logger.info("ℹ️ 没有找到已保存的会话凭据")
            return nil
        }

        cookies = candidateCookies.map { cookie in
            var props = cookie.properties ?? [:]
            props[.domain] = ".quark.cn"
            props[.path] = "/"
            return HTTPCookie(properties: props) ?? cookie
        }

        Self.logger.info("🔑 正在验证会话 (请求网盘根目录 /file/sort)...")
        do {
            let page = try await fetchFiles(parentID: "0", page: 1, pageSize: 5)
            account = acc
            Self.logger.info("✅ 会话验证成功！根目录获取到 \(page.files.count) 个项目，总计 \(page.total ?? page.files.count)")
            try persistSession()
            return account
        } catch {
            if let qe = error as? QuarkError, qe == .authenticationRequired {
            Self.logger.error("❌ session rejected (authentication required)")
                account = nil
                cookies.removeAll()
                try? credentialStore.delete()
                throw error
            } else {
                // Temporary network glitch / timeout / offline.
                // Keep the account as authenticated so user is NOT kicked back to login screen!
                Self.logger.warning("⚠️ session check unavailable; retaining local session")
                account = acc
                return account
            }
        }
    }

    func beginQRCodeLogin() async throws -> QRLoginChallenge {
        guard account == nil else { throw QuarkError.invalidResponse("请先退出当前账号") }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        cookies.removeAll()
        activeChallenge = nil
        let result = try await request("https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin", query: loginQuery())
        try ensureGeneration(generation)
        try requireQRSuccess(result)
        guard let token = members(result)?["token"] as? String, !token.isEmpty else {
            throw QuarkError.invalidResponse("二维码响应缺少 data.members.token")
        }
        let url = try buildURL("https://su.quark.cn/4_eMHBJ", query: [
            "token": token, "client_id": "532", "ssb": "weblogin", "uc_param_str": "",
            "uc_biz_str": "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"
        ])
        let challenge = QRLoginChallenge(token: token, qrURL: url, createdAt: now())
        activeChallenge = challenge
        return challenge
    }

    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState {
        guard activeChallenge?.token == challenge.token else { return .expired }
        let generation = sessionGeneration
        guard now().timeIntervalSince(challenge.createdAt) < Self.localQRCodeTimeout else {
            activeChallenge = nil
            cookies.removeAll()
            return .expired
        }
        var query = loginQuery()
        query["token"] = challenge.token
        let result = try await request("https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken", query: query)
        try ensureGeneration(generation)
        if integer(result["status"]) == 50004001 { return .waiting }
        try requireQRSuccess(result)
        guard result["message"] as? String == "ok",
              let ticket = members(result)?["service_ticket"] as? String, !ticket.isEmpty else {
            throw QuarkError.invalidResponse("扫码响应缺少 data.members.service_ticket")
        }
        let accountResult = try await request("https://pan.quark.cn/account/info", query: ["st": ticket, "lw": "scan"])
        try ensureGeneration(generation)
        try requireAccountSuccess(accountResult)
        guard !cookies.isEmpty else { throw QuarkError.authenticationRequired }
        // A ticket alone does not establish a working authenticated drive session.
        _ = try await fetchFiles(parentID: "0", page: 1, pageSize: 1)
        try ensureGeneration(generation)
        let authenticated = Account(accountId: UUID().uuidString, displayName: "夸克账号",
                                    authenticationState: .authenticated)
        account = authenticated
        do { try persistSession() }
        catch {
            account = nil
            cookies.removeAll()
            activeChallenge = nil
            throw error
        }
        activeChallenge = nil
        return .authenticated(authenticated)
    }

    func cancelQRCodeLogin() {
        sessionGeneration &+= 1
        activeChallenge = nil
        if account == nil {
            cookies.removeAll()
        }
    }

    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        guard account != nil else { throw QuarkError.authenticationRequired }
        return try await fetchFiles(parentID: parentID, page: page, pageSize: pageSize)
    }

    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        guard account != nil else { throw QuarkError.authenticationRequired }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, page > 0, (1...100).contains(pageSize) else { throw QuarkError.invalidSearchQuery }
        var parameters = driveQuery()
        parameters.merge(["q": term, "_page": String(page), "_size": String(pageSize),
                          "_fetch_total": "1", "_sort": "file_type:desc,updated_at:desc", "_is_hl": "1"]) { _, new in new }
        let result = try await request(Self.api + "/file/search", query: parameters)
        try requireDriveSuccess(result)
        guard let data = result["data"] as? [String: Any], let list = data["list"] as? [[String: Any]] else {
            throw QuarkError.invalidResponse("搜索响应缺少 data.list")
        }
        let files = try list.map { item -> CloudFile in
            guard let fid = item["fid"] as? String, !fid.isEmpty,
                  let name = item["file_name"] as? String,
                  let parent = item["pdir_fid"] as? String else { throw QuarkError.invalidResponse("搜索结果字段不完整") }
            let isDirectory = (item["dir"] as? Bool) ?? ((integer(item["file_type"]) ?? -1) == 0)
            let stamp = (item["updated_at"] as? NSNumber)?.doubleValue
            let date = stamp.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0) : nil }
            return CloudFile(fileId: fid, parentId: parent, name: name,
                size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                fileExtension: isDirectory ? "" : (name as NSString).pathExtension.lowercased(),
                modifiedAt: date, isDirectory: isDirectory)
        }
        let total = integer((result["metadata"] as? [String: Any])?["_total"])
        return CloudFilePage(files: files, page: page, pageSize: pageSize, total: total)
    }

    private func fetchFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        guard !parentID.isEmpty, page > 0, (1...100).contains(pageSize) else {
            throw QuarkError.invalidResponse("目录 ID、页码或每页数量无效")
        }
        var query = driveQuery()
        query.merge(["pdir_fid": parentID, "_page": String(page), "_size": String(pageSize),
                     "_sort": "file_name:asc"]) { _, new in new }
        let result = try await request(Self.api + "/file/sort", query: query)
        try requireDriveSuccess(result)
        guard let data = result["data"] as? [String: Any], let list = data["list"] as? [[String: Any]] else {
            throw QuarkError.invalidResponse("文件列表缺少 data.list")
        }
        let files = try list.map { item -> CloudFile in
            guard let fid = item["fid"] as? String, !fid.isEmpty,
                  let name = item["file_name"] as? String,
                  let parent = item["pdir_fid"] as? String else {
                throw QuarkError.invalidResponse("文件缺少 fid、file_name 或 pdir_fid")
            }
            let directory: Bool
            if let value = item["dir"] as? Bool { directory = value }
            else if let fileType = integer(item["file_type"]) { directory = fileType == 0 }
            else { throw QuarkError.invalidResponse("文件缺少 dir 或 file_type") }
            let timestamp = (item["updated_at"] as? NSNumber)?.doubleValue
            let modified = timestamp.flatMap { value -> Date? in
                guard value.isFinite, value > 0 else { return nil }
                // Defensive seconds/milliseconds normalization; real-account fixtures are pending.
                return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
            }
            return CloudFile(fileId: fid, parentId: parent, name: name,
                             size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                             fileExtension: directory ? "" : (name as NSString).pathExtension.lowercased(),
                             modifiedAt: modified, isDirectory: directory)
        }
        let metadata = result["metadata"] as? [String: Any]
        let total = integer(metadata?["_total"]).flatMap { $0 >= 0 ? $0 : nil }
        return CloudFilePage(files: files, page: page, pageSize: pageSize, total: total)
    }

    /// Resolves a short-lived dedicated video streaming or download URL on demand. The URL is not persisted as media data.
    func playbackResource(fileID: String) async throws -> PlaybackResource {
        guard account != nil else { throw QuarkError.authenticationRequired }
        guard !fileID.isEmpty, fileID != "0" else { throw QuarkError.invalidResponse("文件 ID 无效") }

        // 1. Attempt Quark's dedicated video streaming endpoint (/file/v2/play)
        // This routes through Quark's high-speed video CDN edge clusters (video-play-*-zb.drive.quark.cn),
        // completely bypassing the 100 KB/s rate-limiting imposed on generic /file/download endpoints.
        var playQuery = driveQuery()
        playQuery.merge(["sys": "win32", "ve": "2.5.56"]) { _, new in new }
        let playBody: [String: Any] = [
            "fid": fileID,
            "resolutions": "original,4k,2k,super,high,low",
            "supports": "fmp4,hls,mp4"
        ]
        let playbackCorrelation = diagnostics?.makeCorrelationID()

        if let playResult = try? await request(Self.api + "/file/v2/play", query: playQuery, body: playBody, correlationID: playbackCorrelation),
           let status = integer(playResult["status"]), status == 200,
           let data = playResult["data"] as? [String: Any],
           let videoList = data["video_list"] as? [[String: Any]], !videoList.isEmpty {
            for item in videoList {
                if let videoInfo = item["video_info"] as? [String: Any],
                   let value = videoInfo["url"] as? String,
                   let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil,
                   url.user == nil, url.password == nil {
                    Self.logger.info("🎬 成功获取专属视频流直链")
                    return PlaybackResource(fileID: fileID, url: url, cookies: cookies,
                                            requiredHTTPHeaders: ["User-Agent": Self.desktopUserAgent,
                                                                  "Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/"],
                                            expiresAt: nil)
                }
            }
        }

        diagnostics?.record(category: .cloud, level: .notice, event: .requestFallback,
                            correlationID: playbackCorrelation,
                            metadata: [.host(.quarkAPI), .endpoint(.fileDownload), .fallback(true), .reason(.unavailable)])

        // 2. Fallback to generic /file/download if v2/play is unavailable or file is not a playable video
        var query = driveQuery()
        query.merge(["sys": "win32", "ve": "2.5.56", "ut": "", "guid": ""]) { _, new in new }
        let result = try await request(Self.api + "/file/download", query: query, body: ["fids": [fileID]], correlationID: playbackCorrelation)
        try requireDriveSuccess(result)
        guard let entries = result["data"] as? [[String: Any]],
              let entry = entries.first(where: { $0["fid"] as? String == fileID }),
              let value = entry["download_url"] as? String,
              let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw QuarkError.invalidResponse("没有匹配文件的 HTTPS download_url")
        }
        return PlaybackResource(fileID: fileID, url: url, cookies: cookies,
                                requiredHTTPHeaders: ["User-Agent": Self.desktopUserAgent,
                                                      "Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/"],
                                expiresAt: nil)
    }

    func logout() throws {
        sessionGeneration &+= 1
        defer { account = nil; cookies.removeAll(); activeChallenge = nil }
        try credentialStore.delete()
        #if targetEnvironment(simulator)
        let localPath = "/Users/wangbin/.quark_theater_session.json"
        try? FileManager.default.removeItem(atPath: localPath)
        #endif
        Self.logger.info("🚪 已退出登录，清除会话凭据")
    }

    private func persistSession() throws {
        guard let account else { return }
        let stored = StoredQuarkSession(account: account, cookies: cookies)
        try credentialStore.save(JSONEncoder().encode(stored))
        #if targetEnvironment(simulator)
        let localPath = "/Users/wangbin/.quark_theater_session.json"
        let list = cookies.map { c in
            StoredCookie(name: c.name, value: c.value, domain: c.domain, path: c.path,
                         expires: c.expiresDate?.timeIntervalSince1970)
        }
        if let raw = try? JSONEncoder().encode(list) {
            try? raw.write(to: URL(fileURLWithPath: localPath))
        }
        #endif
    }

    private func loginQuery() -> [String: String] {
        ["client_id": "532", "v": "1.2", "request_id": UUID().uuidString]
    }

    private func driveQuery() -> [String: String] {
        ["pr": "ucpro", "fr": "pc", "uc_param_str": "", "__dt": "1000",
         "__t": String(Int64(now().timeIntervalSince1970 * 1000))]
    }

    private func buildURL(_ endpoint: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: endpoint) else { throw QuarkError.invalidResponse("请求地址无效") }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw QuarkError.invalidResponse("请求参数无效") }
        return url
    }

    private func request(_ endpoint: String, query: [String: String], body: [String: Any]? = nil,
                         correlationID: DiagnosticCorrelationID? = nil) async throws -> [String: Any] {
        let generation = sessionGeneration
        let url = try buildURL(endpoint, query: query)
        let correlationID = correlationID ?? diagnostics?.makeCorrelationID()
        let start = DispatchTime.now().uptimeNanoseconds
        let endpointKind = Self.diagnosticEndpoint(for: url)
        func latency() -> Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        func recordFailure(_ error: Error, status: Int? = nil) {
            var metadata: [DiagnosticMetadata] = [.host(.quarkAPI), .endpoint(endpointKind),
                                                   .latencyMilliseconds(latency()), .outcome(.failed),
                                                   .reason(Self.diagnosticReason(for: error))]
            if let status { metadata.append(.httpStatus(status)) }
            diagnostics?.record(category: .cloud, level: .error, event: .requestFailed,
                                correlationID: correlationID, metadata: metadata)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = body == nil ? "GET" : "POST"
        let isDownloadOrPlay = endpoint.contains("/download") || endpoint.contains("/play")
        request.setValue(isDownloadOrPlay ? Self.desktopUserAgent : Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false

        // Exact Cookie header string formatting, matching the verified Python verifier
        let cookiePairs = cookies.map { "\($0.name)=\($0.value)" }
        if !cookiePairs.isEmpty {
            request.setValue(cookiePairs.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        Self.logger.info("📡 发送夸克请求端点: \(endpointKind.rawValue, privacy: .public), Cookie 数量: \(self.cookies.count)")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
            try ensureGeneration(generation)
        } catch {
            recordFailure(error)
            throw error
        }
        Self.logger.info("📥 received response HTTP \(response.statusCode, privacy: .public)")

        guard response.url?.host == url.host else {
            let error = QuarkError.invalidResponse("接口重定向主机未验证")
            recordFailure(error, status: response.statusCode)
            throw error
        }
        switch response.statusCode {
        case 200...299: break
        case 401: let error = QuarkError.authenticationRequired; recordFailure(error, status: response.statusCode); throw error
        case 403: let error = QuarkError.forbidden; recordFailure(error, status: response.statusCode); throw error
        case 429: let error = QuarkError.rateLimited; recordFailure(error, status: response.statusCode); throw error
        default: let error = QuarkError.httpStatus(response.statusCode); recordFailure(error, status: response.statusCode); throw error
        }

        // Capture incoming Set-Cookie headers
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        var hasNewCookies = false
        for cookie in incoming {
            var props = cookie.properties ?? [:]
            props[.domain] = ".quark.cn"
            props[.path] = "/"
            let normalized = HTTPCookie(properties: props) ?? cookie
            cookies.removeAll { $0.name == normalized.name }
            cookies.append(normalized)
            hasNewCookies = true
        }
        if hasNewCookies {
            try? persistSession()
        }

        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let error = QuarkError.invalidResponse("响应不是 JSON 对象")
            recordFailure(error, status: response.statusCode)
            throw error
        }
        let businessStatus = integer(result["status"])
        let businessCode = integer(result["code"])
        let isQRWaiting = endpointKind == .loginTicket && businessStatus == 50004001
        let businessRejected = !isQRWaiting && !Self.isBusinessSuccess(endpoint: endpointKind,
                                                                        status: businessStatus,
                                                                        code: businessCode)
        let businessReason: DiagnosticReason = {
            switch businessStatus {
            case 401: return .authenticationRequired
            case 403: return .forbidden
            case 429: return .rateLimited
            default: return .unavailable
            }
        }()
        var metadata: [DiagnosticMetadata] = [.host(.quarkAPI), .endpoint(endpointKind),
                                               .httpStatus(response.statusCode), .latencyMilliseconds(latency()),
                                               .outcome(businessRejected ? .failed : (isQRWaiting ? .partial : .succeeded)),
                                               .reason(businessRejected ? businessReason : .none)]
        if let businessCode { metadata.append(.businessCode(businessCode)) }
        if businessRejected {
            if let businessStatus { metadata.append(.errorCode(businessStatus)) }
            diagnostics?.record(category: .cloud, level: .error, event: .requestFailed,
                                correlationID: correlationID, metadata: metadata)
        } else {
            diagnostics?.record(category: .cloud, level: .info, event: .requestCompleted,
                                correlationID: correlationID, metadata: metadata)
        }
        return result
    }

    private static func diagnosticEndpoint(for url: URL) -> DiagnosticQuarkEndpoint {
        switch url.path {
        case "/cas/ajax/getTokenForQrcodeLogin": return .loginToken
        case "/cas/ajax/getServiceTicketByQrcodeToken": return .loginTicket
        case "/account/info": return .accountInfo
        case "/1/clouddrive/file/sort": return .fileSort
        case "/1/clouddrive/file/search": return .fileSearch
        case "/1/clouddrive/file/v2/play": return .filePlay
        case "/1/clouddrive/file/download": return .fileDownload
        default: return .unknown
        }
    }

    /// Business status values differ between the QR/account APIs and the drive APIs.
    /// Keep this interpretation here so diagnostics match the same contract checks
    /// performed by the operation before it returns a result to its caller.
    private static func isBusinessSuccess(endpoint: DiagnosticQuarkEndpoint,
                                           status: Int?, code: Int?) -> Bool {
        switch endpoint {
        case .loginToken:
            return status == 2000000 && (code == nil || code == 0)
        case .loginTicket:
            return status == 2000000 && (code == nil || code == 0)
        case .accountInfo:
            // The account exchange endpoint has historically returned an empty
            // object with only Set-Cookie. If it supplies business fields, accept
            // either the QR API's success value or a conventional HTTP-style 200.
            guard let status else { return code == nil || code == 0 }
            return (status == 200 || status == 2000000) && (code == nil || code == 0)
        case .fileSort, .fileSearch, .filePlay, .fileDownload:
            return (status.map { $0 == 200 } ?? true) && (code.map { $0 == 0 } ?? true)
        case .unknown:
            return true
        }
    }

    private static func diagnosticReason(for error: Error) -> DiagnosticReason {
        if let error = error as? QuarkError {
            switch error {
            case .authenticationRequired: return .authenticationRequired
            case .forbidden: return .forbidden
            case .rateLimited: return .rateLimited
            case .httpStatus(let code) where code == 408: return .timedOut
            case .httpStatus: return .unavailable
            case .invalidResponse: return .invalidResponse
            default: return .unknown
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timedOut
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost: return .networkUnavailable
            default: return .unknown
            }
        }
        return error is CancellationError ? .cancelled : .unknown
    }

    private func ensureGeneration(_ generation: Int) throws {
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    static func cookie(_ cookie: HTTPCookie, matches url: URL, at now: Date) -> Bool {
        guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        
        let hostIsQuark = host == "quark.cn" || host.hasSuffix(".quark.cn")
        let domain = cookie.domain.lowercased()
        let cookieIsQuark = domain.contains("quark.cn")
        
        // Any cookie issued by Quark (*.quark.cn) matches all Quark endpoints
        if hostIsQuark && cookieIsQuark {
            return true
        }
        
        let clean = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let hostMatches = host == clean || host.hasSuffix("." + clean)
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
        return hostMatches && pathMatches
    }

    private func members(_ value: [String: Any]) -> [String: Any]? {
        (value["data"] as? [String: Any])?["members"] as? [String: Any]
    }

    private func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private func requireQRSuccess(_ value: [String: Any]) throws {
        guard let status = integer(value["status"]) else { throw QuarkError.invalidResponse("缺少二维码 status") }
        guard status == 2000000 else { throw QuarkError.server(code: status, message: "二维码服务拒绝请求") }
    }

    private func requireAccountSuccess(_ value: [String: Any]) throws {
        guard Self.isBusinessSuccess(endpoint: .accountInfo,
                                     status: integer(value["status"]),
                                     code: integer(value["code"])) else {
            let status = integer(value["status"]) ?? integer(value["code"]) ?? -1
            throw QuarkError.server(code: status, message: "账号交换服务拒绝请求")
        }
    }

    private func requireDriveSuccess(_ value: [String: Any]) throws {
        guard let status = integer(value["status"]) else { throw QuarkError.invalidResponse("缺少网盘 status") }
        let code = integer(value["code"]) ?? 0
        guard status == 200, code == 0 else {
            if status == 401 { throw QuarkError.authenticationRequired }
            if status == 403 { throw QuarkError.forbidden }
            if status == 429 { throw QuarkError.rateLimited }
            throw QuarkError.server(code: code == 0 ? status : code, message: "网盘服务拒绝请求")
        }
    }
}
