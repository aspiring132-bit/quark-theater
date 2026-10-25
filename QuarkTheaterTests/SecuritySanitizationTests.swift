import XCTest
@testable import QuarkTheater

final class SecuritySanitizationTests: XCTestCase {
    func testSanitizeURLRedactsQueryParameters() {
        let rawURL = "https://pan.quark.cn/v2/play?auth_key=secret_123456789&sign=abcdef&user_id=10001"
        let sanitized = LogSanitizer.sanitizeURLString(rawURL)

        XCTAssertFalse(sanitized.contains("secret_123456789"))
        XCTAssertFalse(sanitized.contains("abcdef"))
        XCTAssertTrue(sanitized.contains("pan.quark.cn/v2/play"))
    }

    func testSanitizeHeadersRedactsAuthorizationAndCookies() {
        let headers: [String: String] = [
            "Authorization": "Basic YWRtaW46c2VjcmV0MTIz",
            "Cookie": "_UP_A4A_11_=xyz; __uid=12345; token=supersecret",
            "User-Agent": "QuarkTheater/1.2",
            "Range": "bytes=0-1024"
        ]

        let sanitized = LogSanitizer.sanitizeHeaders(headers)
        XCTAssertEqual(sanitized["Authorization"], "[REDACTED]")
        XCTAssertEqual(sanitized["Cookie"], "[REDACTED]")
        XCTAssertEqual(sanitized["User-Agent"], "QuarkTheater/1.2")
        XCTAssertEqual(sanitized["Range"], "bytes=0-1024")
    }

    func testLogSanitizerTextRedaction() {
        let logMessage = "Request failed for token=xyz123 with cookie: p_skey=abcd and password=mypassword"
        let sanitized = LogSanitizer.sanitize(logMessage)

        XCTAssertFalse(sanitized.contains("xyz123"))
        XCTAssertFalse(sanitized.contains("abcd"))
        XCTAssertFalse(sanitized.contains("mypassword"))
    }
}
