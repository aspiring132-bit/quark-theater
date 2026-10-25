import Foundation
import XCTest
@testable import QuarkTheater

@MainActor
final class VLCOriginHTTPProxyBufferTests: XCTestCase {
    func testVODPlaylistTimelineParsingAndBufferedRanges() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        segment0.ts
        #EXTINF:4.5,
        segment1.ts
        #EXT-X-ENDLIST
        """
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: URL(string: "http://example.com/vod.m3u8")!)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.segments.count, 2)
        XCTAssertEqual(timeline?.segments[0].range, PlaybackTimeRange(start: 0.0, end: 6.0))
        XCTAssertEqual(timeline?.segments[1].range, PlaybackTimeRange(start: 6.0, end: 10.5))
    }

    func testLivePlaylistWithoutEndlistReturnsNilTimeline() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        segment0.ts
        #EXTINF:4.5,
        segment1.ts
        """
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: URL(string: "http://example.com/live.m3u8")!)
        XCTAssertNil(timeline)
    }

    func testByteRangeSegmentsWithPerURIImplicitOffset() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXT-X-TARGETDURATION:10
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:1000@0
        media_a.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:1500
        media_a.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:2000@500
        media_b.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:1000
        media_b.mp4
        #EXT-X-ENDLIST
        """
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: URL(string: "http://example.com/vod.m3u8")!)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.segments.count, 4)
        // media_a: 0..1000, then offset 1000..2500
        XCTAssertEqual(timeline?.segments[0].byteRangeOffset, 0)
        XCTAssertEqual(timeline?.segments[0].byteRangeLength, 1000)
        XCTAssertEqual(timeline?.segments[1].byteRangeOffset, 1000)
        XCTAssertEqual(timeline?.segments[1].byteRangeLength, 1500)
        // media_b: 500..2500, then offset 2500..3500
        XCTAssertEqual(timeline?.segments[2].byteRangeOffset, 500)
        XCTAssertEqual(timeline?.segments[2].byteRangeLength, 2000)
        XCTAssertEqual(timeline?.segments[3].byteRangeOffset, 2500)
        XCTAssertEqual(timeline?.segments[3].byteRangeLength, 1000)
    }

    func testByteRangeLengthOnlyWithoutPriorRangeForURIRejected() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:1000
        media_first.mp4
        #EXT-X-ENDLIST
        """
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: URL(string: "http://example.com/vod.m3u8")!)
        // Segment with length-only but no prior range on that URI must be rejected
        XCTAssertEqual(timeline?.segments.count ?? 0, 0)
    }

    func testByteRangeMalformedZeroOrNegativeRejected() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXTINF:0,
        zerodur.mp4
        #EXTINF:0.0,
        zerodurfloat.mp4
        #EXTINF:nan,
        nandur.mp4
        #EXTINF:inf,
        infdur.mp4
        #EXTINF:Infinity,
        infinitydur.mp4
        #EXTINF:-Infinity,
        neginfinitydur.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:0@0
        zero.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:-10@0
        neg.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:abc@xyz
        bad.mp4
        #EXTINF:-2.0,
        negdur.mp4
        #EXTINF:5.0,
        #EXT-X-BYTERANGE:500@-10
        negoff.mp4
        #EXTINF:5.0,
        valid.mp4
        #EXT-X-ENDLIST
        """
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: URL(string: "http://example.com/vod.m3u8")!)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.segments.count, 1)
        XCTAssertEqual(timeline?.segments.first?.uri, "valid.mp4")
        XCTAssertEqual(timeline?.segments.first?.range, PlaybackTimeRange(start: 0.0, end: 5.0))
    }

    func testBoundedTimelineCapsAt2000EntriesPreservingCumulativePresentationTime() {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:5"
        ]
        // Generate 2500 segments of 5.0 seconds each
        // Segments 0 .. 499 will be evicted; segments 500 .. 2499 will be retained (exactly 2000 entries).
        // Segment 500 starts at 500 * 5.0 = 2500.0, ends at 2505.0.
        // Last segment 2499 starts at 2499 * 5.0 = 12495.0, ends at 12500.0.
        for i in 0..<2500 {
            lines.append("#EXTINF:5.0,")
            lines.append("segment_\(i).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        let manifest = lines.joined(separator: "\n")
        let baseURL = URL(string: "http://example.com/vod.m3u8")!

        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: baseURL)
        XCTAssertNotNil(timeline)
        guard let timeline else { return }

        // Assert exact bounded size
        XCTAssertEqual(timeline.segments.count, 2000)
        XCTAssertEqual(timeline.segments.count, VLCOriginHTTPProxy.maxTimelineEntries)

        // Retained first time must be > 0 (strictly preserved cumulative absolute time)
        let firstRetained = timeline.segments.first!
        XCTAssertEqual(firstRetained.uri, "segment_500.ts")
        XCTAssertGreaterThan(firstRetained.range.start, 0.0)
        XCTAssertEqual(firstRetained.range.start, 2500.0)
        XCTAssertEqual(firstRetained.range.end, 2505.0)

        let lastRetained = timeline.segments.last!
        XCTAssertEqual(lastRetained.uri, "segment_2499.ts")
        XCTAssertEqual(lastRetained.range.start, 12495.0)
        XCTAssertEqual(lastRetained.range.end, 12500.0)

        // Verify lookup entries:
        // Evicted keys are removed
        let evictedKey = VLCOriginHTTPProxy.SegmentKey(url: URL(string: "http://example.com/segment_0.ts")!, byteRange: nil)
        XCTAssertNil(timeline.segmentLookup[evictedKey])

        let evictedKey499 = VLCOriginHTTPProxy.SegmentKey(url: URL(string: "http://example.com/segment_499.ts")!, byteRange: nil)
        XCTAssertNil(timeline.segmentLookup[evictedKey499])

        // Retained keys are present
        let retainedKey500 = VLCOriginHTTPProxy.SegmentKey(url: URL(string: "http://example.com/segment_500.ts")!, byteRange: nil)
        XCTAssertEqual(timeline.segmentLookup[retainedKey500], PlaybackTimeRange(start: 2500.0, end: 2505.0))

        let retainedKey2499 = VLCOriginHTTPProxy.SegmentKey(url: URL(string: "http://example.com/segment_2499.ts")!, byteRange: nil)
        XCTAssertEqual(timeline.segmentLookup[retainedKey2499], PlaybackTimeRange(start: 12495.0, end: 12500.0))

        // Total lookup count must not exceed 2000
        XCTAssertEqual(timeline.segmentLookup.count, 2000)
    }

    func testEvictedLookupOnlyRemovesIfMappingToEvictedInterval() {
        // If a shared URI is used multiple times (e.g. repeated or looped segment URL),
        // evicting the first occurrence must not purge the lookup if the lookup key was overwritten by later occurrence
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3"
        ]
        // 2001 segments: first segment is repeated_seg.ts (0..5), followed by 1999 unique segments (5..10000),
        // and finally repeated_seg.ts again at (10000..10005).
        lines.append("#EXTINF:5.0,")
        lines.append("repeated_seg.ts")
        for i in 1...1999 {
            lines.append("#EXTINF:5.0,")
            lines.append("mid_\(i).ts")
        }
        lines.append("#EXTINF:5.0,")
        lines.append("repeated_seg.ts")
        lines.append("#EXT-X-ENDLIST")

        let manifest = lines.joined(separator: "\n")
        let baseURL = URL(string: "http://example.com/vod.m3u8")!
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: baseURL)
        XCTAssertNotNil(timeline)
        guard let timeline else { return }

        XCTAssertEqual(timeline.segments.count, 2000)
        let repeatedKey = VLCOriginHTTPProxy.SegmentKey(url: URL(string: "http://example.com/repeated_seg.ts")!, byteRange: nil)
        // The first occurrence [0, 5] was evicted, but repeatedKey maps to the last occurrence [10000, 10005].
        // It must NOT be evicted from lookup.
        XCTAssertEqual(timeline.segmentLookup[repeatedKey], PlaybackTimeRange(start: 10000.0, end: 10005.0))
    }

    func testMasterPlaylistVariantExtractionAndAudioPlaylistIgnored() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio-1",NAME="English",URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,AUDIO="audio-1"
        video/720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2560000,AUDIO="audio-1"
        video/1080p.m3u8
        """
        let masterURL = URL(string: "http://example.com/master.m3u8")!
        let variants = VLCOriginHTTPProxy.extractVariantPlaylistURLs(manifestText: master, masterURL: masterURL)
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants.contains(URL(string: "http://example.com/video/720p.m3u8")!))
        XCTAssertTrue(variants.contains(URL(string: "http://example.com/video/1080p.m3u8")!))
        XCTAssertFalse(variants.contains(URL(string: "http://example.com/audio/en.m3u8")!))
        XCTAssertFalse(variants.contains(URL(string: "http://example.com/subs/en.m3u8")!))
    }

    func testCoalescerPreservesRangesNearestPlayhead() {
        var coalescer = VLCOriginHTTPProxy.PlaybackRangeCoalescer(maxRanges: 3)
        // Add 3 ranges at 0..5, 10..15, 20..25
        coalescer.add(PlaybackTimeRange(start: 0, end: 5), playhead: 22.0)
        coalescer.add(PlaybackTimeRange(start: 10, end: 15), playhead: 22.0)
        coalescer.add(PlaybackTimeRange(start: 20, end: 25), playhead: 22.0)
        XCTAssertEqual(coalescer.ranges.count, 3)

        // Adding a 4th range at 30..35 with playhead at 22.0
        // Distances from 22.0:
        // [0, 5]: dist 17.0 (farthest)
        // [10, 15]: dist 7.0
        // [20, 25]: dist 0.0
        // [30, 35]: dist 8.0
        // The farthest range [0, 5] should be evicted, keeping [10, 15], [20, 25], [30, 35]
        coalescer.add(PlaybackTimeRange(start: 30, end: 35), playhead: 22.0)
        XCTAssertEqual(coalescer.ranges.count, 3)
        XCTAssertEqual(coalescer.ranges, [
            PlaybackTimeRange(start: 10, end: 15),
            PlaybackTimeRange(start: 20, end: 25),
            PlaybackTimeRange(start: 30, end: 35)
        ])
    }

    func testSegmentCompletionRequiresExactRangeAndContentLength() {
        // Validation helper test
        let fullLengthKnownValid = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: nil,
            statusCode: 200,
            contentRange: nil,
            contentLength: 1000,
            receivedBytes: 1000
        )
        XCTAssertTrue(fullLengthKnownValid)

        let fullLengthMismatch = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: nil,
            statusCode: 200,
            contentRange: nil,
            contentLength: 1000,
            receivedBytes: 999
        )
        XCTAssertFalse(fullLengthMismatch)

        let unknownLengthRejected = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: nil,
            statusCode: 200,
            contentRange: nil,
            contentLength: nil,
            receivedBytes: 1000
        )
        XCTAssertFalse(unknownLengthRejected)

        let rangeRequest200Rejected = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 200, // 200 is rejected for Range request
            contentRange: nil,
            contentLength: 5000,
            receivedBytes: 5000
        )
        XCTAssertFalse(rangeRequest200Rejected)

        let rangeRequest206Matching = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 100-199/1000",
            contentLength: 100,
            receivedBytes: 100
        )
        XCTAssertTrue(rangeRequest206Matching)

        let rangeRequest206StarTotalMatching = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 100-199/*",
            contentLength: 100,
            receivedBytes: 100
        )
        XCTAssertTrue(rangeRequest206StarTotalMatching)

        let rangeRequest206ContentLengthMismatch = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 100-199/1000",
            contentLength: 100,
            receivedBytes: 90
        )
        XCTAssertFalse(rangeRequest206ContentLengthMismatch)

        // Shifted start
        let rangeRequestShiftedStart = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 101-199/1000",
            contentLength: 99,
            receivedBytes: 99
        )
        XCTAssertFalse(rangeRequestShiftedStart)

        // Short end
        let rangeRequestShortEnd = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 100-150/1000",
            contentLength: 51,
            receivedBytes: 51
        )
        XCTAssertFalse(rangeRequestShortEnd)

        // Extended end
        let rangeRequestExtendedEnd = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 100-200/1000",
            contentLength: 101,
            receivedBytes: 101
        )
        XCTAssertFalse(rangeRequestExtendedEnd)

        // Wrong unit in Content-Range
        let rangeRequestWrongUnit = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "items 100-199/1000",
            contentLength: 100,
            receivedBytes: 100
        )
        XCTAssertFalse(rangeRequestWrongUnit)

        // Malformed Content-Range (missing total separator)
        let rangeRequestMalformedContentRange = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "bytes=100-199",
            statusCode: 206,
            contentRange: "bytes 100-199",
            contentLength: 100,
            receivedBytes: 100
        )
        XCTAssertFalse(rangeRequestMalformedContentRange)

        // Malformed requestedRange
        let rangeRequestMalformedRequestedRange = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "invalid-range",
            statusCode: 206,
            contentRange: "bytes 100-199/1000",
            contentLength: 100,
            receivedBytes: 100
        )
        XCTAssertFalse(rangeRequestMalformedRequestedRange)

        // Empty requested range treated as no range requested -> 206 should be rejected
        let emptyRequestedRange206 = VLCOriginHTTPProxy.isSegmentCompletionValid(
            requestedRange: "",
            statusCode: 206,
            contentRange: "bytes 0-99/100",
            contentLength: 100,
            receivedBytes: 100
        )
        XCTAssertFalse(emptyRequestedRange206)
    }

    func testExactSegmentURLAndByteRangeKeyLookup() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:100@0
        part.mp4
        #EXTINF:6.0,
        #EXT-X-BYTERANGE:200@100
        part.mp4
        #EXT-X-ENDLIST
        """
        let baseURL = URL(string: "http://example.com/vod.m3u8")!
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: baseURL)!
        let segURL = URL(string: "http://example.com/part.mp4")!

        let key1 = VLCOriginHTTPProxy.SegmentKey(url: segURL, byteRange: "bytes=0-99")
        let key2 = VLCOriginHTTPProxy.SegmentKey(url: segURL, byteRange: "bytes=100-299")
        let keyBad = VLCOriginHTTPProxy.SegmentKey(url: segURL, byteRange: "bytes=300-399")

        XCTAssertEqual(timeline.segmentLookup[key1], PlaybackTimeRange(start: 0.0, end: 4.0))
        XCTAssertEqual(timeline.segmentLookup[key2], PlaybackTimeRange(start: 4.0, end: 10.0))
        XCTAssertNil(timeline.segmentLookup[keyBad])
    }

    func testDiscontinuityTimelineContinuity() {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXTINF:4.0,
        ad.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:6.0,
        feature.ts
        #EXT-X-ENDLIST
        """
        let timeline = VLCOriginHTTPProxy.parseVODTimeline(manifestText: manifest, manifestURL: URL(string: "http://example.com/vod.m3u8")!)
        XCTAssertNotNil(timeline)
        XCTAssertEqual(timeline?.segments.count, 2)
        XCTAssertEqual(timeline?.segments[0].range, PlaybackTimeRange(start: 0.0, end: 4.0))
        XCTAssertEqual(timeline?.segments[1].range, PlaybackTimeRange(start: 4.0, end: 10.0))
    }

    func testCoalescerMergesAdjacentAndOverlappingIntervals() {
        var coalescer = VLCOriginHTTPProxy.PlaybackRangeCoalescer()
        coalescer.add(PlaybackTimeRange(start: 0.0, end: 6.0))
        coalescer.add(PlaybackTimeRange(start: 6.05, end: 12.0)) // within 0.1s epsilon
        XCTAssertEqual(coalescer.ranges, [PlaybackTimeRange(start: 0.0, end: 12.0)])

        coalescer.add(PlaybackTimeRange(start: 20.0, end: 26.0))
        XCTAssertEqual(coalescer.ranges, [
            PlaybackTimeRange(start: 0.0, end: 12.0),
            PlaybackTimeRange(start: 20.0, end: 26.0)
        ])

        coalescer.add(PlaybackTimeRange(start: 11.95, end: 15.0))
        XCTAssertEqual(coalescer.ranges, [
            PlaybackTimeRange(start: 0.0, end: 15.0),
            PlaybackTimeRange(start: 20.0, end: 26.0)
        ])
    }

    func testProxyBufferedRangesLifecycle() {
        let resource = PlaybackResource(
            fileID: "test",
            url: URL(string: "https://pan.quark.cn/vod.m3u8")!,
            cookies: [],
            requiredHTTPHeaders: ["Origin": "https://pan.quark.cn"],
            expiresAt: nil
        )
        let proxy = VLCOriginHTTPProxy(resource: resource)
        XCTAssertEqual(proxy.currentBufferedRanges(), [])
    }

    func testVLCPlaybackControllerPullsBufferedRanges() {
        let controller = VLCPlaybackController()
        XCTAssertEqual(controller.snapshot.bufferedRanges, [])
    }
}
