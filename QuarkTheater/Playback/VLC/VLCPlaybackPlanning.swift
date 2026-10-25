import Foundation

struct VLCPlaybackCookieInjection: Equatable, Sendable {
    let setCookieValue: String
    let host: String
    let path: String
}

struct VLCPlaybackPlan: Equatable, Sendable {
    let cookieInjections: [VLCPlaybackCookieInjection]
    let mediaOptions: [String]
    /// Preserved required HTTP headers from the playback resource.
    let requiredHTTPHeaders: [String: String]
    /// Headers required by the resource that cannot be represented by supported
    /// TVVLCKit / LibVLC media options (e.g. Origin). LibVLC does not support
    /// an `http-origin` option, so these must be preserved for upstream proxy/adapters.
    let unmappedHTTPHeaders: [String: String]
    /// True when VLC 3.x cannot express a required header and must use the
    /// loopback adapter to preserve it upstream.
    var requiresOriginProxy: Bool { !unmappedHTTPHeaders.isEmpty }

    init(
        cookieInjections: [VLCPlaybackCookieInjection],
        mediaOptions: [String],
        requiredHTTPHeaders: [String: String] = [:],
        unmappedHTTPHeaders: [String: String] = [:]
    ) {
        self.cookieInjections = cookieInjections
        self.mediaOptions = mediaOptions
        self.requiredHTTPHeaders = requiredHTTPHeaders.isEmpty ? unmappedHTTPHeaders : requiredHTTPHeaders
        self.unmappedHTTPHeaders = unmappedHTTPHeaders
    }
}

enum VLCPlaybackPlanning {
    /// TVVLCKit (LibVLC 3.x) does not provide a supported media option for `Origin`
    /// (e.g. `:http-origin` is not recognized by LibVLC's HTTP access module).
    /// Attempting to invent an unsupported option can cause stream rejection or
    /// silent parsing failures. Therefore, applicable cookies and recognized options
    /// (`:http-user-agent`, `:http-referrer`) are configured for VLC, while all required
    /// headers—including `Origin`—are preserved in `requiredHTTPHeaders` and
    /// `unmappedHTTPHeaders` for upstream adapter or proxy boundaries.
    static func plan(resource: PlaybackResource) -> VLCPlaybackPlan {
        let host = resource.url.host?.lowercased() ?? ""
        let injections: [VLCPlaybackCookieInjection] = host.isEmpty ? [] : PlaybackProbe.applicableCookies(resource.cookies, url: resource.url).map {
            var value = "\($0.name)=\($0.value)"
            if $0.isSecure { value += "; Secure" }
            let path = $0.path.isEmpty ? "/" : $0.path
            return VLCPlaybackCookieInjection(setCookieValue: value, host: host, path: path)
        }

        var unmapped: [String: String] = [:]
        let options = resource.requiredHTTPHeaders.compactMap { name, value -> String? in
            switch name.lowercased() {
            case "user-agent": return ":http-user-agent=\(value)"
            case "referer": return ":http-referrer=\(value)"
            default:
                unmapped[name] = value
                return nil
            }
        }.sorted()

        return VLCPlaybackPlan(
            cookieInjections: injections,
            mediaOptions: options,
            requiredHTTPHeaders: resource.requiredHTTPHeaders,
            unmappedHTTPHeaders: unmapped
        )
    }

    static func seekTargetMilliseconds(currentSeconds: Double, durationSeconds: Double,
                                       deltaSeconds: Double) -> Int64 {
        guard currentSeconds.isFinite, durationSeconds.isFinite, deltaSeconds.isFinite,
              durationSeconds > 0 else { return 0 }
        let target = min(max(currentSeconds + deltaSeconds, 0), durationSeconds)
        return Int64((target * 1000).rounded())
    }
}
