import Foundation

struct PlaybackProbeResult {
    let statusCode: Int
    let supportsRange: Bool
    let contentType: String?
}

/// A header-only Range probe. Cancel as soon as headers arrive, including when a server
/// ignores Range and returns 200, so probing cannot download an entire movie into RAM.
final class PlaybackProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlaybackProbeResult, Error>?
    private var session: URLSession?
    private var cancelled = false

    func inspect(_ resource: PlaybackResource) async throws -> PlaybackProbeResult {
        guard resource.url.scheme?.lowercased() == "https" else {
            throw QuarkError.unsupportedPlayback("下载地址不是 HTTPS；未放宽 ATS。")
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCache = nil
                config.timeoutIntervalForRequest = 20
                config.timeoutIntervalForResource = 25
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: resource.url)
                for (name, value) in resource.requiredHTTPHeaders where name.lowercased() != "cookie" {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                let cookies = Self.applicableCookies(resource.cookies, url: resource.url)
                for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let task = session.dataTask(with: request)
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    static func applicableCookies(_ cookies: [HTTPCookie], url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let hostIsQuark = host == "quark.cn" || host.hasSuffix(".quark.cn")
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            if hostIsQuark && domain.contains("quark.cn") {
                return (!cookie.isSecure || url.scheme == "https") &&
                    (cookie.expiresDate.map { $0 > Date() } ?? true)
            }
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let domainMatches = host == bare || host.hasSuffix("." + bare)
            let path = url.path.isEmpty ? "/" : url.path
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) &&
                (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https") &&
                (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(QuarkError.invalidResponse("播放探测未返回 HTTP 响应")))
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 200, 206:
            finish(.success(PlaybackProbeResult(statusCode: http.statusCode,
                supportsRange: http.statusCode == 206 && http.value(forHTTPHeaderField: "Content-Range") != nil,
                contentType: http.mimeType)))
        case 401: finish(.failure(QuarkError.authenticationRequired))
        case 403: finish(.failure(QuarkError.forbidden))
        case 429: finish(.failure(QuarkError.rateLimited))
        default: finish(.failure(QuarkError.httpStatus(http.statusCode)))
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Redirect target authentication has not been verified. Stop at the boundary.
        finish(.failure(QuarkError.unsupportedPlayback("下载地址发生重定向，需先核实目标域和鉴权规则。")))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<PlaybackProbeResult, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }
}
