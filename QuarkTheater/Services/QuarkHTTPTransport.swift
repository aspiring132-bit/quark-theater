import Foundation

@MainActor
protocol QuarkHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral URLSession keeps credentials out of shared cookies and disk caches.
/// Redirects are rejected: automatically forwarding an authenticated request to an
/// unverified host would leak credentials. Any future redirect must be validated.
@MainActor
final class URLSessionQuarkTransport: QuarkHTTPTransport {
    private let delegate: QuarkRedirectDelegate
    private let session: URLSession

    init() {
        let delegate = QuarkRedirectDelegate()
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw QuarkError.invalidResponse("响应不是 HTTP")
        }
        return (data, response)
    }
}

private final class QuarkRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
