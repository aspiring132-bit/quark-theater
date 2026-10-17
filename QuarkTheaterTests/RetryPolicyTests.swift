import XCTest
@testable import QuarkTheater

final class RetryPolicyTests: XCTestCase {
    func testTransientNetworkFailureUsesBoundedExponentialDelays() {
        let policy = RetryPolicy()
        let error = URLError(.timedOut)
        XCTAssertEqual(policy.delay(for: error, retriesUsed: 0), 1)
        XCTAssertEqual(policy.delay(for: error, retriesUsed: 1), 2)
        XCTAssertNil(policy.delay(for: error, retriesUsed: 2))
        XCTAssertNil(policy.delay(for: error, retriesUsed: -1))
    }

    func testServerOutageCanRetryButPermissionAndBusinessFailuresCannot() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(for: QuarkError.httpStatus(503), retriesUsed: 0), 1)
        let errors: [QuarkError] = [.forbidden, .authenticationRequired, .rateLimited,
                                   .httpStatus(403), .httpStatus(401), .httpStatus(429),
                                   .server(code: 32003, message: "fixture"),
                                   .unsupportedPlayback("fixture"), .invalidResponse("fixture")]
        for error in errors {
            XCTAssertNil(policy.delay(for: error, retriesUsed: 0), "Do not automatically retry \(error)")
        }
    }

    func testUnknownAVFailureAndCancellationDoNotRetry() {
        let policy = RetryPolicy()
        XCTAssertNil(policy.delay(for: NSError(domain: "AVFoundationErrorDomain", code: -11800), retriesUsed: 0))
        XCTAssertNil(policy.delay(for: URLError(.cancelled), retriesUsed: 0))
        XCTAssertNil(policy.delay(for: CancellationError(), retriesUsed: 0))
    }

    func testWrappedTransientNetworkFailureCanRetry() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        XCTAssertEqual(RetryPolicy().delay(for: error, retriesUsed: 0), 1)
    }

    func testZeroRetryBudgetDoesNotRetry() {
        XCTAssertNil(RetryPolicy(maximumRetries: 0).delay(for: URLError(.timedOut), retriesUsed: 0))
    }
}
