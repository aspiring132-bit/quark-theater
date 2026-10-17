import Foundation

/// Native adapter for the pinned MIT QuarkPan contracts. See API-ADAPTER.md.
@MainActor
final class LiveQuarkClient: QuarkClient {
    private let transport: any QuarkHTTPTransport
    private let credentialStore: any CredentialStore
    private let now: () -> Date
    private var cookies: [HTTPCookie] = []
    private var account: Account?
    private var activeChallenge: QRLoginChallenge?
    private var sessionGeneration = 0
    private static let api = "https://drive-pc.quark.cn/1/clouddrive"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.71 Safari/537.36 Core/1.94.225.400 QQBrowser/12.2.5544.400"
    private static let loginUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
    // A local waiting limit, not an asserted server QR validity period.
    static let localQRCodeTimeout: TimeInterval = 300

    convenience init() throws {
        self.init(transport: URLSessionQuarkTransport(), credentialStore: KeychainCredentialStore())
    }

    init(transport: any QuarkHTTPTransport, credentialStore: any CredentialStore,
         now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.now = now
    }

    func restoreSession() async throws -> Account? {
        guard let data = try credentialStore.load() else { return nil }
        let stored: StoredQuarkSession
        do { stored = try JSONDecoder().decode(StoredQuarkSession.self, from: data) }
        catch { throw QuarkError.invalidResponse("安全凭据无法解码，请退出后重新登录") }
        cookies = try stored.cookies().filter { $0.expiresDate.map { $0 > now() } ?? true }
        guard !cookies.isEmpty else { try logout(); return nil }
        do {
            _ = try await fetchFiles(parentID: "0", page: 1, pageSize: 1)
            account = stored.account
            try persistSession()
            return account
        } catch {
            account = nil
            if error as? QuarkError == .authenticationRequired {
                cookies.removeAll()
                try credentialStore.delete()
            }
            throw error
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
        _ = try await request("https://pan.quark.cn/account/info", query: ["st": ticket, "lw": "scan"])
        try ensureGeneration(generation)
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
        cookies.removeAll()
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

    /// Resolves a short-lived download URL on demand. The URL is not persisted as media data.
    func playbackResource(fileID: String) async throws -> PlaybackResource {
        guard account != nil else { throw QuarkError.authenticationRequired }
        guard !fileID.isEmpty, fileID != "0" else { throw QuarkError.invalidResponse("文件 ID 无效") }
        var query = driveQuery()
        query.merge(["sys": "win32", "ve": "2.5.56", "ut": "", "guid": ""]) { _, new in new }
        let result = try await request(Self.api + "/file/download", query: query, body: ["fids": [fileID]])
        try requireDriveSuccess(result)
        guard let entries = result["data"] as? [[String: Any]],
              let entry = entries.first(where: { $0["fid"] as? String == fileID }),
              let value = entry["download_url"] as? String,
              let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw QuarkError.invalidResponse("没有匹配文件的 HTTPS download_url")
        }
        // Keep scope attributes; never copy a whole Quark Cookie header to an arbitrary CDN host.
        return PlaybackResource(fileID: fileID, url: url, cookies: cookies,
                                requiredHTTPHeaders: ["User-Agent": Self.userAgent,
                                                      "Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/"],
                                expiresAt: nil)
    }

    func logout() throws {
        sessionGeneration &+= 1
        defer { account = nil; cookies.removeAll(); activeChallenge = nil }
        try credentialStore.delete()
    }

    private func persistSession() throws {
        guard let account else { return }
        let stored = try StoredQuarkSession(account: account, cookies: cookies)
        try credentialStore.save(JSONEncoder().encode(stored))
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

    private func request(_ endpoint: String, query: [String: String], body: [String: Any]? = nil) async throws -> [String: Any] {
        let generation = sessionGeneration
        let url = try buildURL(endpoint, query: query)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = body == nil ? "GET" : "POST"
        let host = url.host?.lowercased()
        let usesLoginAgent = host == "uop.quark.cn" || host == "pan.quark.cn"
        request.setValue(usesLoginAgent ? Self.loginUserAgent : Self.userAgent, forHTTPHeaderField: "User-Agent")
        if usesLoginAgent {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.httpShouldHandleCookies = false
        let matching = cookies.filter { Self.cookie($0, matches: url, at: now()) }
        if !matching.isEmpty {
            HTTPCookie.requestHeaderFields(with: matching).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await transport.send(request)
        try ensureGeneration(generation)
        guard response.url?.host == url.host else { throw QuarkError.invalidResponse("接口重定向主机未验证") }
        switch response.statusCode {
        case 200...299: break
        case 401: throw QuarkError.authenticationRequired
        case 403: throw QuarkError.forbidden
        case 429: throw QuarkError.rateLimited
        default: throw QuarkError.httpStatus(response.statusCode)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for cookie in incoming {
            let host = url.host?.lowercased() ?? ""
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard host == domain || host.hasSuffix("." + domain), domain == "quark.cn" || domain.hasSuffix(".quark.cn") else { continue }
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if cookie.expiresDate.map({ $0 > now() }) ?? true { cookies.append(cookie) }
        }
        cookies.removeAll { $0.expiresDate.map { $0 <= now() } ?? false }
        if !incoming.isEmpty { try persistSession() }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuarkError.invalidResponse("响应不是 JSON 对象")
        }
        return result
    }

    private func ensureGeneration(_ generation: Int) throws {
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    static func cookie(_ cookie: HTTPCookie, matches url: URL, at now: Date) -> Bool {
        guard let host = url.host?.lowercased(), cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        let domain = cookie.domain.lowercased()
        let hostMatches = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
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
