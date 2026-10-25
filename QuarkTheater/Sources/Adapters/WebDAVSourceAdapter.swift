import Foundation

@MainActor
final class WebDAVSourceAdapter: StorageSourceAdapter {
    let sourceID: String
    let sourceType: StorageSourceType = .webdav
    let endpointURL: URL
    let username: String?
    var isAvailable: Bool { true }

    private let session: URLSession

    init(sourceID: String, endpointURL: URL, username: String? = nil, session: URLSession = .shared) {
        self.sourceID = sourceID
        self.endpointURL = endpointURL
        self.username = username
        self.session = session
    }

    nonisolated static func isPlaintextHTTP(url: String) -> Bool {
        url.lowercased().hasPrefix("http://")
    }

    nonisolated static func makeBasicAuthHeader(username: String?, password: String?) -> String? {
        guard let username, let password, !username.isEmpty else { return nil }
        let credential = "\(username):\(password)"
        guard let data = credential.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    private func getAuthHeader() throws -> String? {
        guard let username else { return nil }
        let password = try SourceCredentialStore.shared.loadSecret(for: sourceID, key: "password") ?? ""
        return Self.makeBasicAuthHeader(username: username, password: password)
    }

    func testConnection() async throws -> SourceConnectionStatus {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.timeoutInterval = 10

        if let auth = try? getAuthHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .configError(reason: "非 HTTP 协议响应")
            }

            if http.statusCode == 200 || http.statusCode == 207 {
                return .connected
            } else if http.statusCode == 401 || http.statusCode == 403 {
                return .needsReauth
            } else {
                return .configError(reason: "HTTP 状态码 \(http.statusCode)")
            }
        } catch {
            return .unreachable(reason: error.localizedDescription)
        }
    }

    func listFiles(folderID: String, page: Int, pageSize: Int) async throws -> CloudFilePage {
        let targetURL: URL
        let normalizedFolder = folderID.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedFolder.isEmpty || normalizedFolder == "0" || normalizedFolder == "/" {
            targetURL = endpointURL
        } else if normalizedFolder.hasPrefix("http://") || normalizedFolder.hasPrefix("https://"),
                  let fullURL = URL(string: normalizedFolder) {
            targetURL = fullURL
        } else {
            let pathComponent = normalizedFolder.hasPrefix("/") ? String(normalizedFolder.dropFirst()) : normalizedFolder
            targetURL = endpointURL.appendingPathComponent(pathComponent)
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.timeoutInterval = 15

        if let auth = try? getAuthHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuarkError.invalidResponse("非 HTTP 协议响应")
        }

        guard http.statusCode == 200 || http.statusCode == 207 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw QuarkError.authenticationRequired
            }
            throw QuarkError.server(code: http.statusCode, message: "WebDAV 状态码 \(http.statusCode)")
        }

        let parser = WebDAVXMLParser()
        let allFiles = try parser.parse(xmlData: data, basePath: targetURL.path)

        // Local paging
        let startIndex = (page - 1) * pageSize
        guard startIndex < allFiles.count else {
            return CloudFilePage(files: [], page: page, pageSize: pageSize, total: allFiles.count)
        }
        let endIndex = min(startIndex + pageSize, allFiles.count)
        let pageFiles = Array(allFiles[startIndex..<endIndex])

        return CloudFilePage(files: pageFiles, page: page, pageSize: pageSize, total: allFiles.count)
    }

    func playbackResource(fileID: String) async throws -> PlaybackResource {
        let streamURL: URL
        if fileID.hasPrefix("http://") || fileID.hasPrefix("https://"), let url = URL(string: fileID) {
            streamURL = url
        } else {
            let path = fileID.hasPrefix("/") ? String(fileID.dropFirst()) : fileID
            streamURL = endpointURL.appendingPathComponent(path)
        }

        var headers: [String: String] = [:]
        if let auth = try? getAuthHeader() {
            headers["Authorization"] = auth
        }

        return PlaybackResource(
            fileID: fileID,
            url: streamURL,
            cookies: [],
            requiredHTTPHeaders: headers,
            expiresAt: nil
        )
    }
}
