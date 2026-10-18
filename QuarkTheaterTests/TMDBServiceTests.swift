import Foundation
import XCTest
@testable import QuarkTheater

final class TMDBServiceTests: XCTestCase {
    private func service(handler: @escaping (URLRequest) throws -> (Int, Data)) -> TMDBService {
        StubTMDBURLProtocol.handler = handler
        return TMDBService(session: stubSession())
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTMDBURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func parsed(_ title: String = "Dune", type: MediaType = .movie) -> ParsedMediaName {
        ParsedMediaName(title: title, year: nil, mediaType: type, seasonNumber: nil,
                        episodeNumber: nil, inferredFromParent: false)
    }

    private func response(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["results": rows])
    }

    func testLaterAliasResultIsRetainedAfterEarlierNonEmptyResponse() async throws {
        let service = service { request in
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = components?.queryItems?.first(where: { $0.name == "query" })?.value
            let type = request.url?.path.hasSuffix("/tv") == true ? "tv" : "movie"
            if query == "蛛丝" {
                return (200, self.response([["id": 1, "title": "蛛丝"]]))
            }
            let key = type == "tv" ? "name" : "title"
            return (200, self.response([["id": 2, key: "蜘蛛侠"]]))
        }
        let results = try await service.search(parsed("蛛丝"), apiReadToken: "test")
        XCTAssertTrue(results.contains(where: { $0.id == 1 }))
        XCTAssertTrue(results.contains(where: { $0.id == 2 }))
    }

    func testEndpointTypeProvenanceIsPreserved() async throws {
        let service = service { request in
            let isTV = request.url?.path.hasSuffix("/tv") == true
            let key = isTV ? "name" : "title"
            return (200, self.response([["id": isTV ? 20 : 10, key: "Dune"]]))
        }
        let results = try await service.search(parsed(), apiReadToken: "test")
        XCTAssertEqual(results.first(where: { $0.id == 10 })?.sourceMediaType, .movie)
        XCTAssertEqual(results.first(where: { $0.id == 20 })?.sourceMediaType, .series)
    }

    func testPartialRequestFailuresKeepSuccessfulCandidates() async throws {
        let service = service { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value
            if query == "蛛丝" { return (503, Data()) }
            return (200, self.response([["id": 99, "title": "蜘蛛侠"]]))
        }
        let results = try await service.search(parsed("蛛丝"), apiReadToken: "test")
        XCTAssertTrue(results.contains(where: { $0.id == 99 }))
    }

    func testEachLogicalSearchHasHardRequestCeiling() async throws {
        let counter = RequestCounter()
        let service = service { _ in
            counter.increment()
            return (200, self.response([]))
        }
        _ = try await service.search(parsed("蛛丝"), apiReadToken: "test")
        XCTAssertLessThanOrEqual(counter.value, 8)
    }

    func testAllRequestFailuresSurfaceAnError() async {
        let service = service { _ in (503, Data()) }
        do {
            _ = try await service.search(parsed(), apiReadToken: "test")
            XCTFail("Expected TMDB error")
        } catch let error as TMDBError {
            guard case .rejected(503) = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testDiagnosticsReportSafeAggregateWithoutTitleOrToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmdb-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: directory))
        StubTMDBURLProtocol.handler = { _ in
            return (200, self.response([["id": 7, "title": "Dune"]]))
        }
        let instrumented = TMDBService(session: stubSession(), diagnostics: diagnostics)
        _ = try await instrumented.search(parsed("Dune"), apiReadToken: "secret-token")
        await diagnostics.waitForPendingOperations()
        let encoded = try JSONEncoder().encode(diagnostics.records)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("Dune"))
        XCTAssertFalse(text.contains("secret-token"))
        XCTAssertTrue(diagnostics.records.contains { $0.category == .scraping && $0.event == .scrapingSearchCompleted })
        XCTAssertTrue(diagnostics.records.contains { record in
            record.metadata["outcome"] == .string(DiagnosticOutcome.succeeded.rawValue)
        })
    }

    @MainActor
    func testDiagnosticsReportSafeFailureWithStatusAndReason() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tmdb-diagnostics-failure-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = Diagnostics(store: DiagnosticsStore(directoryURL: directory))
        StubTMDBURLProtocol.handler = { _ in (503, Data()) }
        let instrumented = TMDBService(session: stubSession(), diagnostics: diagnostics)
        do {
            _ = try await instrumented.search(parsed("Dune"), apiReadToken: "secret-token")
            XCTFail("Expected TMDB error")
        } catch {
            await diagnostics.waitForPendingOperations()
            XCTAssertTrue(diagnostics.records.contains { record in
                record.category == .scraping && record.event == .requestFailed && record.metadata["httpStatus"] == .int(503)
            })
            XCTAssertTrue(diagnostics.records.contains { record in
                record.metadata["outcome"] == .string(DiagnosticOutcome.failed.rawValue)
            })
        }
    }

}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class StubTMDBURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TMDBError.badResponse)
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
