import XCTest
@testable import QuarkTheater

// Pure cookie filtering tests only. These do not perform playback or claim CDN validation.
final class PlaybackProbeCookieTests: XCTestCase {
    private func cookie(domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "fixture", .value: "not-a-real-cookie", .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testCookieCannotLeakToUnrelatedOrLookalikeDomain() throws {
        let cookies = [cookie(domain: ".quark.cn")]
        XCTAssertEqual(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video"))).count, 1)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://quark.cn.example.net/video"))).isEmpty)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://evilquark.cn/video"))).isEmpty)
    }

    func testHostOnlyCookieIsNotSentToSubdomain() throws {
        let cookies = [cookie(domain: "drive.quark.cn")]
        XCTAssertEqual(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video"))).count, 1)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://cdn.drive.quark.cn/video"))).isEmpty)
    }

    func testCookiePathRequiresSegmentBoundary() throws {
        let cookies = [cookie(domain: ".quark.cn", path: "/video")]
        XCTAssertEqual(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video/file"))).count, 1)
        XCTAssertTrue(PlaybackProbe.applicableCookies(cookies, url: try XCTUnwrap(URL(string: "https://drive.quark.cn/videos/file"))).isEmpty)
    }

    func testSecureAndExpiredCookiesAreExcluded() throws {
        XCTAssertTrue(PlaybackProbe.applicableCookies([cookie(domain: ".quark.cn")],
            url: try XCTUnwrap(URL(string: "http://drive.quark.cn/video"))).isEmpty)
        XCTAssertTrue(PlaybackProbe.applicableCookies([cookie(domain: ".quark.cn", expires: Date(timeIntervalSince1970: 1))],
            url: try XCTUnwrap(URL(string: "https://drive.quark.cn/video"))).isEmpty)
    }
}
