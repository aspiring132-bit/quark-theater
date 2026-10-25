import Foundation
import XCTest
@testable import QuarkTheater

final class VLCPlaybackPlanningTests: XCTestCase {
    private func cookie(domain: String, path: String = "/", secure: Bool = true, name: String = "session", value: String = "fixture-value") -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    func testPlanPreservesUnmappedHeadersInsteadOfDroppingThem() throws {
        let resource = PlaybackResource(
            fileID: "fixture-file",
            url: try XCTUnwrap(URL(string: "https://video.quark.cn/media/episode.mp4")),
            cookies: [cookie(domain: ".quark.cn"), cookie(domain: "unrelated.example")],
            requiredHTTPHeaders: [
                "User-Agent": "QuarkFixture/1.0",
                "Referer": "https://pan.quark.cn/",
                "Origin": "https://pan.quark.cn"
            ],
            expiresAt: nil
        )

        let plan = VLCPlaybackPlanning.plan(resource: resource)

        XCTAssertEqual(plan.cookieInjections.count, 1)
        XCTAssertEqual(plan.cookieInjections[0].host, "video.quark.cn")
        XCTAssertEqual(plan.cookieInjections[0].path, "/")
        XCTAssertTrue(plan.cookieInjections[0].setCookieValue.hasPrefix("session=fixture-value"))
        XCTAssertTrue(plan.mediaOptions.contains(":http-user-agent=QuarkFixture/1.0"))
        XCTAssertTrue(plan.mediaOptions.contains(":http-referrer=https://pan.quark.cn/"))
        XCTAssertEqual(plan.unmappedHTTPHeaders["Origin"], "https://pan.quark.cn")
        XCTAssertEqual(plan.requiredHTTPHeaders["Origin"], "https://pan.quark.cn")
        XCTAssertEqual(plan.requiredHTTPHeaders["User-Agent"], "QuarkFixture/1.0")
        XCTAssertEqual(plan.requiredHTTPHeaders["Referer"], "https://pan.quark.cn/")
    }

    func testPlanPreservesOriginWithoutInventingUnsupportedOptions() throws {
        let resource = PlaybackResource(
            fileID: "origin-test",
            url: try XCTUnwrap(URL(string: "https://video.quark.cn/media/stream.m3u8")),
            cookies: [],
            requiredHTTPHeaders: [
                "Origin": "https://pan.quark.cn",
                "Referer": "https://pan.quark.cn/",
                "X-Custom-Header": "CustomValue"
            ],
            expiresAt: nil
        )

        let plan = VLCPlaybackPlanning.plan(resource: resource)

        // TVVLCKit / LibVLC does not support an :http-origin option.
        // It must not be invented in mediaOptions, but must be preserved in requiredHTTPHeaders/unmappedHTTPHeaders.
        XCTAssertFalse(plan.mediaOptions.contains { $0.localizedCaseInsensitiveContains("origin") })
        XCTAssertEqual(plan.unmappedHTTPHeaders["Origin"], "https://pan.quark.cn")
        XCTAssertEqual(plan.unmappedHTTPHeaders["X-Custom-Header"], "CustomValue")
        XCTAssertEqual(plan.requiredHTTPHeaders["Origin"], "https://pan.quark.cn")
        XCTAssertTrue(plan.mediaOptions.contains(":http-referrer=https://pan.quark.cn/"))
    }

    func testOriginPlanUsesLoopbackAdapterAndPreservesRequestHeaders() throws {
        let resource = PlaybackResource(
            fileID: "origin-proxy",
            url: try XCTUnwrap(URL(string: "https://video.quark.cn/media/movie.mp4")),
            cookies: [cookie(domain: ".quark.cn", name: "sid", value: "abc")],
            requiredHTTPHeaders: [
                "User-Agent": "QuarkFixture/1.0",
                "Referer": "https://pan.quark.cn/",
                "Origin": "https://pan.quark.cn"
            ],
            expiresAt: nil
        )

        let plan = VLCPlaybackPlanning.plan(resource: resource)

        XCTAssertTrue(plan.requiresOriginProxy)
        let request = try XCTUnwrap(VLCOriginHTTPProxy.upstreamRequest(for: resource, range: "bytes=4-9"))
        XCTAssertEqual(request.url, resource.url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://pan.quark.cn")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://pan.quark.cn/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "QuarkFixture/1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-9")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sid=abc")
    }

    func testPlanFiltersCookiesAndFormatsSecureAttribute() throws {
        let matchingSecure = cookie(domain: ".quark.cn", path: "/media", secure: true, name: "c1", value: "v1")
        let matchingInsecure = cookie(domain: "video.quark.cn", path: "/", secure: false, name: "c2", value: "v2")
        let unrelated = cookie(domain: "other.com", path: "/", secure: true, name: "c3", value: "v3")

        let resource = PlaybackResource(
            fileID: "cookie-file",
            url: try XCTUnwrap(URL(string: "https://video.quark.cn/media/file.mp4")),
            cookies: [matchingSecure, matchingInsecure, unrelated],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )

        let plan = VLCPlaybackPlanning.plan(resource: resource)

        XCTAssertEqual(plan.cookieInjections.count, 2)
        let injection1 = plan.cookieInjections.first { $0.setCookieValue.contains("c1=v1") }
        let injection2 = plan.cookieInjections.first { $0.setCookieValue.contains("c2=v2") }

        XCTAssertNotNil(injection1)
        XCTAssertTrue(injection1?.setCookieValue.contains("; Secure") == true)
        XCTAssertEqual(injection1?.path, "/media")

        XCTAssertNotNil(injection2)
        XCTAssertFalse(injection2?.setCookieValue.contains("; Secure") == true)
        XCTAssertEqual(injection2?.path, "/")
    }

    func testPlanHandlesEmptyHeadersAndCookies() throws {
        let resource = PlaybackResource(
            fileID: "empty-file",
            url: try XCTUnwrap(URL(string: "https://video.quark.cn/media/1.mp4")),
            cookies: [],
            requiredHTTPHeaders: [:],
            expiresAt: nil
        )

        let plan = VLCPlaybackPlanning.plan(resource: resource)
        XCTAssertTrue(plan.cookieInjections.isEmpty)
        XCTAssertTrue(plan.mediaOptions.isEmpty)
        XCTAssertTrue(plan.unmappedHTTPHeaders.isEmpty)
        XCTAssertTrue(plan.requiredHTTPHeaders.isEmpty)
    }

    func testSeekTargetClampsToDurationAndReturnsMilliseconds() {
        XCTAssertEqual(VLCPlaybackPlanning.seekTargetMilliseconds(currentSeconds: 10, durationSeconds: 120, deltaSeconds: 15), 25_000)
        XCTAssertEqual(VLCPlaybackPlanning.seekTargetMilliseconds(currentSeconds: 5, durationSeconds: 120, deltaSeconds: -15), 0)
        XCTAssertEqual(VLCPlaybackPlanning.seekTargetMilliseconds(currentSeconds: 119, durationSeconds: 120, deltaSeconds: 15), 120_000)
        XCTAssertEqual(VLCPlaybackPlanning.seekTargetMilliseconds(currentSeconds: 0, durationSeconds: 0, deltaSeconds: 10), 0)
        XCTAssertEqual(VLCPlaybackPlanning.seekTargetMilliseconds(currentSeconds: .nan, durationSeconds: 120, deltaSeconds: 10), 0)
    }
}
