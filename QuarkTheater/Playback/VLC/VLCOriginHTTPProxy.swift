import Foundation
import Network

/// A loopback-only HTTP adapter for LibVLC 3.x.
///
/// TVVLCKit exposes `http-user-agent` and `http-referrer`, but not `Origin` or
/// arbitrary request headers.  This adapter keeps the media URL private to the
/// app, forwards byte ranges upstream, and streams the response without
/// buffering the media in memory.
final class VLCOriginHTTPProxy: NSObject, @unchecked Sendable {
    private let resource: PlaybackResource
    private let allowLoopbackForTesting: Bool
    private let queue = DispatchQueue(label: "org.quarktheater.vlc-origin-proxy")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var streamPath = "/"
    private var stopped = true
    private var routes: [String: URL] = [:]
    private var routeTokensByURL: [String: String] = [:]
    private var routeLRU: [String] = []
    private static let maxPlaylistBytes = 2 * 1024 * 1024
    private static let maxRouteCount = 4096

    init(resource: PlaybackResource, allowLoopbackForTesting: Bool = false) {
        self.resource = resource
        self.allowLoopbackForTesting = allowLoopbackForTesting
        super.init()
    }

    var isRunning: Bool { queue.sync { listener != nil && !stopped } }

    func start() async throws -> URL {
        guard isAllowedTarget(resource.url) else {
            throw VLCOriginHTTPProxyError.listenerUnavailable
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let listener = self.listener, let port = listener.port, !self.stopped {
                        continuation.resume(returning: Self.localURL(port: port, path: self.streamPath))
                        return
                    }
                    do {
                        let endpoint = NWEndpoint.hostPort(
                            host: NWEndpoint.Host("127.0.0.1"),
                            port: NWEndpoint.Port(rawValue: 0)!
                        )
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = endpoint
                        let newListener = try NWListener(using: parameters, on: .any)
                        let path = "/" + UUID().uuidString.lowercased()
                        self.streamPath = path
                        self.routes = [path: self.resource.url]
                        self.routeTokensByURL = [self.resource.url.absoluteString: path]
                        self.routeLRU = [path]
                        self.stopped = false
                        self.listener = newListener
                        self.readyContinuation = continuation
                        newListener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = newListener.port else {
                                    self.failStart(VLCOriginHTTPProxyError.listenerUnavailable)
                                    return
                                }
                                self.readyContinuation?.resume(returning: Self.localURL(port: port, path: path))
                                self.readyContinuation = nil
                            case .failed:
                                self.failStart(VLCOriginHTTPProxyError.listenerUnavailable)
                            case .cancelled:
                                self.failStart(CancellationError())
                            default:
                                break
                            }
                        }
                        newListener.newConnectionHandler = { [weak self] connection in
                            self?.accept(connection)
                        }
                        newListener.start(queue: self.queue)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [weak self] in
            self?.stop()
        })
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.readyContinuation?.resume(throwing: CancellationError())
            self.readyContinuation = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.routes.removeAll()
            self.routeTokensByURL.removeAll()
            self.routeLRU.removeAll()
        }
    }

    static func upstreamRequest(
        for resource: PlaybackResource,
        range: String?,
        method: String = "GET",
        allowLoopbackForTesting: Bool = false
    ) -> URLRequest? {
        guard (allowLoopbackForTesting && isLoopback(resource.url) || isAllowedUpstreamURL(resource.url)),
              ["GET", "HEAD"].contains(method.uppercased()) else { return nil }
        var request = URLRequest(url: resource.url)
        request.httpMethod = method.uppercased()
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        // The proxy streams bytes and forwards Content-Length.  Never let
        // URLSession negotiate a transfer/content encoding that could make
        // that length refer to a different representation.
        for (name, value) in resource.requiredHTTPHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let applicable = PlaybackProbe.applicableCookies(resource.cookies, url: resource.url)
        if !applicable.isEmpty, request.value(forHTTPHeaderField: "Cookie") == nil {
            let cookie = applicable.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let range, !range.isEmpty { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    private static func localURL(port: NWEndpoint.Port, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")!
    }

    private func failStart(_ error: Error) {
        queue.async { [weak self] in
            guard let self, let continuation = self.readyContinuation else { return }
            self.readyContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                connection.cancel()
                return
            }
            let request = ProxyConnection(proxy: self, connection: connection)
            self.connections[ObjectIdentifier(request)] = request
            request.start()
        }
    }

    private func remove(_ connection: ProxyConnection) {
        queue.async { [weak self] in self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    private func isExpectedPath(_ path: String) -> Bool { path == streamPath }

    private func targetURL(for path: String) -> URL? {
        // Called from the listener's serial queue by ProxyConnection.
        routes[path]
    }

    private func proxyURL(for target: URL) -> URL? {
        guard isAllowedTarget(target) else { return nil }
        return queue.sync {
            let key = target.absoluteString
            if let existing = routeTokensByURL[key] {
                routeLRU.removeAll { $0 == existing }
                routeLRU.append(existing)
                guard let listener, let port = listener.port else { return nil }
                return Self.localURL(port: port, path: existing)
            }
            let token = "/" + UUID().uuidString.lowercased()
            routes[token] = target
            routeTokensByURL[key] = token
            routeLRU.append(token)
            while routeLRU.count > Self.maxRouteCount {
                let evicted = routeLRU.removeFirst()
                if let url = routes.removeValue(forKey: evicted) { routeTokensByURL.removeValue(forKey: url.absoluteString) }
            }
            guard let listener, let port = listener.port else { return nil }
            return Self.localURL(port: port, path: token)
        }
    }

    private static func isAllowedUpstreamURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        guard url.scheme?.lowercased() == "https" else {
            let host = url.host?.lowercased()
            return url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
        }
        return true
    }

    private func isAllowedTarget(_ url: URL) -> Bool {
        if allowLoopbackForTesting && Self.isLoopback(url) { return Self.isAllowedUpstreamURL(url) }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.hasSuffix(".local"),
              !Self.isIPLiteral(host) else { return false }
        let root = resource.url.host?.lowercased() ?? ""
        return host == root || host == "quark.cn" || host.hasSuffix(".quark.cn")
    }

    private static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased())
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false } || host.contains(":")
    }

    private func resource(for target: URL) -> PlaybackResource {
        let isSameOrigin = ProxyConnection.sameOrigin(resource.url, target)
        let publicHeaders = Set(["origin", "referer", "user-agent"])
        let headers = resource.requiredHTTPHeaders.filter { name, _ in
            isSameOrigin || publicHeaders.contains(name.lowercased())
        }
        return PlaybackResource(fileID: resource.fileID, url: target, cookies: resource.cookies,
                                requiredHTTPHeaders: headers, expiresAt: resource.expiresAt)
    }

    private enum VLCOriginHTTPProxyError: Error { case listenerUnavailable, unsupportedHLS, invalidPlaylist }

    private final class ProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private final class ResponseDispositionBox: @unchecked Sendable {
            let handler: (URLSession.ResponseDisposition) -> Void
            init(_ handler: @escaping (URLSession.ResponseDisposition) -> Void) { self.handler = handler }
        }
        private weak var proxy: VLCOriginHTTPProxy?
        private let connection: NWConnection
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var receivedRequest = Data()
        private var currentTargetURL: URL?
        private var currentResource: PlaybackResource?
        private var currentMethod = "GET"
        private var upstreamFinished = false
        private var responseStarted = false
        private var pendingSends = 0
        private var finishSent = false
        private var isPlaylist = false
        private var playlistResponse: HTTPURLResponse?
        private var playlistBody = Data()
        private var cancelled = false
        private let lock = NSLock()

        init(proxy: VLCOriginHTTPProxy, connection: NWConnection) {
            self.proxy = proxy
            self.connection = connection
            super.init()
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.cancel() }
                if case .cancelled = state { self?.cancel() }
            }
            connection.start(queue: proxy?.queue ?? DispatchQueue.global(qos: .userInitiated))
            receiveRequest()
        }

        func cancel() {
            lock.lock()
            if cancelled { lock.unlock(); return }
            cancelled = true
            lock.unlock()
            task?.cancel()
            session?.invalidateAndCancel()
            connection.cancel()
            proxy?.remove(self)
        }

        private func receiveRequest() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, !self.cancelled else { return }
                if let data { self.receivedRequest.append(data) }
                if let range = self.receivedRequest.range(of: Data("\r\n\r\n".utf8)) {
                    self.handleRequest(Data(self.receivedRequest[..<range.lowerBound]))
                } else if isComplete || error != nil || self.receivedRequest.count >= 256 * 1024 {
                    self.sendStatus(400, headers: [("Content-Length", "0")], body: nil, final: true)
                } else {
                    self.receiveRequest()
                }
            }
        }

        private func handleRequest(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8),
                  let first = text.split(separator: "\r\n", omittingEmptySubsequences: false).first else {
                sendStatus(400, headers: [("Content-Length", "0")], body: nil, final: true); return
            }
            let pieces = first.split(separator: " ")
            guard pieces.count >= 2, let proxy,
                  ["GET", "HEAD"].contains(String(pieces[0]).uppercased()),
                  let path = pieces[1].split(separator: "?", maxSplits: 1).first.map(String.init),
                  let target = proxy.targetURL(for: path),
                  target.user == nil,
                  ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
                sendStatus(404, headers: [("Content-Length", "0")], body: nil, final: true); return
            }
            let method = String(pieces[0]).uppercased()
            currentMethod = method
            let headerLines = text.split(separator: "\r\n").dropFirst()
            let range = headerLines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1).dropFirst().first?.trimmingCharacters(in: .whitespaces)
            let targetResource = proxy.resource(for: target)
            currentResource = targetResource
            guard let request = VLCOriginHTTPProxy.upstreamRequest(for: targetResource, range: range.map { String($0) }, method: method, allowLoopbackForTesting: proxy.allowLoopbackForTesting) else {
                sendStatus(400, headers: [("Content-Length", "0")], body: nil, final: true); return
            }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCache = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60 * 60 * 24
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            currentTargetURL = target
            task = session?.dataTask(with: request)
            task?.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                responseStarted = true
                sendStatus(502, headers: [("Content-Length", "0")], body: nil, final: true)
                completionHandler(.cancel)
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            isPlaylist = currentMethod == "GET" && http.statusCode == 200 &&
                (contentType.contains("mpegurl") || contentType.contains("x-mpegurl") ||
                 currentTargetURL?.pathExtension.lowercased() == "m3u8")
            if isPlaylist {
                playlistResponse = http
                completionHandler(.allow)
                return
            }
            let allowed = Set(["Content-Length", "Content-Range", "Accept-Ranges", "Content-Type", "ETag", "Last-Modified"])
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
               !encoding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               encoding.caseInsensitiveCompare("identity") != .orderedSame {
                // Do not forward a compressed body with the origin's
                // Content-Length.  URLSession may transparently decode it,
                // so the only safe generic behavior is to fail before bytes
                // are emitted.
                responseStarted = true
                sendStatus(502, headers: [("Content-Length", "0")], body: nil, final: true)
                completionHandler(.cancel)
                return
            }
            let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
                let name = String(describing: key)
                guard allowed.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
                return (name, String(describing: value))
            }
            responseStarted = true
            let disposition = ResponseDispositionBox(completionHandler)
            sendStatus(http.statusCode, headers: headers, body: nil, final: false) { disposition.handler(.allow) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !data.isEmpty else { return }
            if isPlaylist {
                guard playlistBody.count + data.count <= VLCOriginHTTPProxy.maxPlaylistBytes else {
                    responseStarted = true
                    sendStatus(502, headers: [("Content-Length", "0")], body: nil, final: true)
                    task?.cancel()
                    return
                }
                playlistBody.append(data)
                return
            }
            task?.suspend()
            send(data, final: false) { [weak self] in
                self?.task?.resume()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            var redirected = request
            guard let resource = currentResource else {
                completionHandler(nil)
                return
            }
            guard let redirectedURL = request.url,
                  let previousURL = response.url,
                  let oldScheme = previousURL.scheme?.lowercased(),
                  let newScheme = redirectedURL.scheme?.lowercased(),
                  ["https", "http"].contains(newScheme),
                  !(oldScheme == "https" && newScheme == "http") else {
                completionHandler(nil)
                return
            }
            guard let proxy, proxy.isAllowedTarget(redirectedURL) else {
                completionHandler(nil)
                return
            }
            let sameOrigin = Self.sameOrigin(previousURL, redirectedURL)
            // URLSession can copy headers from the original request.  Clear
            // all sensitive/custom fields first, then reconstruct only the
            // explicitly allowed resource headers.
            for name in resource.requiredHTTPHeaders.keys {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            let publicHeaders = Set(["origin", "referer", "user-agent"])
            for (name, value) in resource.requiredHTTPHeaders where sameOrigin || publicHeaders.contains(name.lowercased()) {
                guard name.caseInsensitiveCompare("cookie") != .orderedSame else { continue }
                redirected.setValue(value, forHTTPHeaderField: name)
            }
            redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if sameOrigin {
                // Re-evaluate domain/path/secure constraints against the
                // redirect target, not the original media URL.
                let cookies = PlaybackProbe.applicableCookies(resource.cookies, url: redirectedURL)
                if !cookies.isEmpty {
                    redirected.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
                }
            }
            completionHandler(redirected)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            upstreamFinished = true
            if error == nil && isPlaylist && !responseStarted {
                do {
                    guard let response = playlistResponse, let base = response.url else { throw VLCOriginHTTPProxyError.invalidPlaylist }
                    guard let text = String(data: playlistBody, encoding: .utf8),
                          text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
                        let body = playlistBody
                        responseStarted = true
                        sendStatus(200, headers: [("Content-Type", response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"), ("Content-Length", String(body.count))], body: body, final: true)
                        finishIfReady()
                        return
                    }
                    let body = try rewritePlaylist(playlistBody, baseURL: base)
                    responseStarted = true
                    sendStatus(200, headers: [("Content-Type", "application/vnd.apple.mpegurl"),
                                               ("Content-Length", String(body.count))], body: body, final: true)
                } catch {
                    responseStarted = true
                    sendStatus(502, headers: [("Content-Length", "0")], body: nil, final: true)
                }
            }
            if error != nil && !responseStarted {
                responseStarted = true
                sendStatus(502, headers: [("Content-Length", "0")], body: nil, final: true)
            } else if !finishSent {
                // A final empty send requests a clean FIN after all queued
                // body chunks.  This avoids truncating the last chunk while
                // still allowing cancellation to tear down the task.
                send(Data(), final: true)
            }
            finishIfReady()
        }

        fileprivate static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
                  lhs.host?.lowercased() == rhs.host?.lowercased() else { return false }
            let lhsPort = lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80)
            let rhsPort = rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80)
            return lhsPort == rhsPort
        }

        private func rewritePlaylist(_ data: Data, baseURL: URL) throws -> Data {
            guard let text = String(data: data, encoding: .utf8) else { throw VLCOriginHTTPProxyError.invalidPlaylist }
            var output: [String] = []
            for line in text.components(separatedBy: .newlines) {
                var rewritten = line
                if line.contains("URI=\"") {
                    rewritten = try rewriteURIAttributes(line, baseURL: baseURL)
                } else if !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    rewritten = try rewriteURI(line, baseURL: baseURL)
                }
                output.append(rewritten)
            }
            return Data(output.joined(separator: "\n").utf8)
        }

        private func rewriteURIAttributes(_ line: String, baseURL: URL) throws -> String {
            var result = line
            var searchStart = result.startIndex
            while let range = result.range(of: "URI=\"", range: searchStart..<result.endIndex) {
                let valueStart = range.upperBound
                guard let end = result[valueStart...].firstIndex(of: "\"") else { throw VLCOriginHTTPProxyError.invalidPlaylist }
                let raw = String(result[valueStart..<end])
                let replacement = try rewriteURI(raw, baseURL: baseURL)
                result.replaceSubrange(valueStart..<end, with: replacement)
                guard let nextSearchStart = result.index(valueStart, offsetBy: replacement.count + 1, limitedBy: result.endIndex) else {
                    break
                }
                searchStart = nextSearchStart
            }
            return result
        }

        private func rewriteURI(_ raw: String, baseURL: URL) throws -> String {
            let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(raw.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            let trimmed = String(raw.dropFirst(leading.count).dropLast(trailing.count))
            guard let target = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""), target.user == nil,
                  let proxy, let local = proxy.proxyURL(for: target) else {
                throw VLCOriginHTTPProxyError.invalidPlaylist
            }
            return leading + local.absoluteString + trailing
        }

        private func sendStatus(_ code: Int, headers: [(String, String)], body: Data?, final: Bool, completion: (@Sendable () -> Void)? = nil) {
            var bytes = Data("HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))\r\nConnection: close\r\n".utf8)
            for (name, value) in headers { bytes.append(contentsOf: Data("\(name): \(value)\r\n".utf8)) }
            bytes.append(contentsOf: Data("\r\n".utf8))
            if let body { bytes.append(body) }
            send(bytes, final: final, completion: completion)
        }

        private func send(_ data: Data, final: Bool, completion: (@Sendable () -> Void)? = nil) {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            if final { finishSent = true }
            pendingSends += 1
            lock.unlock()
            connection.send(content: data.isEmpty ? nil : data, isComplete: final, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                self.pendingSends -= 1
                let shouldCancel = error != nil
                self.lock.unlock()
                if shouldCancel { self.cancel() }
                completion?()
                if final { self.cancel() }
                self.finishIfReady()
            })
        }

        private func finishIfReady() {
            lock.lock()
            let done = upstreamFinished && pendingSends == 0
            lock.unlock()
            if done { cancel() }
        }
    }
}
