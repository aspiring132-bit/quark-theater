# Implementation Plan: VOD HLS Playback Buffered-Segment Estimate

- **Date:** 2026-10-24
- **Target Path:** `docs/superpowers/plans/2026-10-24-vod-hls-buffer-estimate.md`
- **Design Reference:** `docs/superpowers/specs/2026-10-24-playback-buffer-lgpl-and-remote-seek-design.md` (Topic 1: Section 2 & AC-BUF-01..06)
- **Status:** Pending Review

---

## 1. Goal and Bounded Scope

Implement network-fetched segment buffer estimation inside `VLCOriginHTTPProxy`, forward completed timeline intervals to `VLCPlaybackController`, and render the secondary buffer intervals on `PlayerScreen`'s scrubber.

### Bounded Scope:
- **Strictly VOD HLS:** Only manifests terminating with `#EXT-X-ENDLIST` (or explicit VOD playlist type) produce timeline mappings.
- **Suppression:** Direct MP4 playback and live/sliding HLS playlists (without `#EXT-X-ENDLIST`) emit empty ranges (`[]`), suppressing the buffer bar to avoid false expectations.
- **Network-Fetch Approximation Principle:** Explicitly labeled as `"网络已下载分片（近似缓冲）"` / `"Network-Fetched Segment Range (Approximation)"`, distinguishing upstream proxy network completion from LibVLC decoder-resident frames.
- **Strict Segment Completion:** Segments are registered only when upstream returns HTTP 200/206, byte-ranges match completely, and the response matches the active playback generation counter.
- **State and Memory Caps:** Playlist entry limit of 2,000 segments, maximum 50 coalesced non-contiguous ranges, adjacent range merge threshold $\le 0.1\text{s}$.
- **Exclusions:** No modifications to episode title display, series badges, or external remotes.

---

## 2. Architecture and Data Flow

```
[Upstream Quark CDN]
        |
        v HTTP Responses (200 / 206)
[VLCOriginHTTPProxy]
   ├── HLSSegmentTimelineParser (Parses #EXTINF, #EXT-X-BYTERANGE, #EXT-X-DISCONTINUITY, #EXT-X-ENDLIST)
   ├── Active Variant Segment Table (Tracks segment URI/Range -> timeline interval [start, end))
   ├── Generation Filter (Discards late-arriving segments from prior playback generations)
   └── Coalesced Time Range Store (Merges adjacent segments, caps at 50 ranges)
        |
        v Event / Polled Snapshot: [PlaybackTimeRange]
[VLCPlaybackController] (Populates PlaybackSnapshot.bufferedRanges)
        |
        v Published MainActor Coordinator State
[PlaybackCoordinator.bufferedRanges]
        |
        v SwiftUI Rendering
[PlayerScreen Scrubber GeometryReader] (Renders secondary multi-range track bars)
```

---

## 3. Step-by-Step TDD Implementation Plan

### Step 1: Define `HLSPlaylistTimeline` and Unit Models
**Files:**
- Create: `QuarkTheater/Playback/VLC/HLSTimelineParser.swift`
- Create: `QuarkTheaterTests/HLSTimelineParserTests.swift`

1. **Write Test (RED):**
   - Test parsing a simple VOD m3u8 string with `#EXTINF:6.0,` segments and `#EXT-X-ENDLIST`.
   - Verify parsed segment intervals: `[0.0, 6.0)`, `[6.0, 12.0)`.
   - Test sliding / live playlist without `#EXT-X-ENDLIST`: parser identifies `isVOD == false` and yields no timeline intervals.
   - Test `#EXT-X-BYTERANGE:1024@0` mapping.
   - Test `#EXT-X-DISCONTINUITY` keeps a continuous playback timeline using cumulative duration.
2. **Run Test:**
   - Execute: `xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/HLSTimelineParserTests`
   - Expected: RED (types do not exist).
3. **Minimal Implementation (GREEN):**
   - Implement `HLSTimelineParser` parsing lines, accumulating segment durations, detecting `#EXT-X-ENDLIST`, and building a lookup table of `SegmentKey(uri, range)` to `PlaybackTimeRange`.
4. **Run Test:**
   - Re-run command; verify tests pass GREEN.

---

### Step 2: Implement Bounded Segment Range Coalescing Logic
**Files:**
- Create: `QuarkTheater/Playback/VLC/PlaybackRangeCoalescer.swift`
- Create: `QuarkTheaterTests/PlaybackRangeCoalescerTests.swift`

1. **Write Test (RED):**
   - Test merging overlapping or contiguous intervals (e.g., `[0, 6]` and `[6, 12]` $\rightarrow$ `[0, 12]`, with epsilon $\le 0.1\text{s}$).
   - Test keeping separate non-contiguous intervals (e.g., `[0, 6]` and `[20, 26]`).
   - Test bounded capacity: enforce maximum 50 ranges by pruning intervals furthest from the current playback head.
2. **Run Test:**
   - Execute: `xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/PlaybackRangeCoalescerTests`
   - Expected: RED.
3. **Minimal Implementation (GREEN):**
   - Implement `PlaybackRangeCoalescer` with interval merging and bounded pruning logic.
4. **Run Test:**
   - Re-run command; verify tests pass GREEN.

---

### Step 3: Integrate Timeline Tracking into `VLCOriginHTTPProxy`
**Files:**
- Modify: `QuarkTheater/Playback/VLC/VLCOriginHTTPProxy.swift`
- Create: `QuarkTheaterTests/VLCOriginHTTPProxyBufferTests.swift`

1. **Write Test (RED):**
   - Use local loopback or mock URLSession harness in `VLCOriginHTTPProxyBufferTests`.
   - Simulate proxy serving a VOD playlist followed by downloading segments 1 and 2.
   - Assert `proxy.currentBufferedRanges()` returns `[0.0, 12.0)`.
   - Simulate an error (HTTP 500 or incomplete payload) on segment 3; assert interval for segment 3 is NOT added.
   - Increment `playbackGeneration`; verify responses from old generation are ignored.
   - Verify direct MP4 requests return `[]` for buffered ranges.
2. **Run Test:**
   - Execute: `xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/VLCOriginHTTPProxyBufferTests`
   - Expected: RED.
3. **Minimal Implementation (GREEN):**
   - In `VLCOriginHTTPProxy`:
     - Maintain `activeTimeline: HLSTimeline?`.
     - In `handlePlaylistRequest`, if playlist is VOD (`#EXT-X-ENDLIST`), parse and store segment lookup table. If not VOD, clear timeline.
     - In `handleSegmentRequest`, upon upstream status 200/206 and full byte delivery matching current `playbackGeneration`, notify `PlaybackRangeCoalescer`.
     - Provide thread-safe accessor `currentBufferedRanges() -> [PlaybackTimeRange]`.
4. **Run Test:**
   - Re-run command; verify tests pass GREEN.

---

### Step 4: Wire Buffer Ranges into `VLCPlaybackController` and `PlaybackCoordinator`
**Files:**
- Modify: `QuarkTheater/Playback/VLC/VLCPlaybackController.swift`
- Modify: `QuarkTheaterTests/VLCPlaybackControllerTests.swift`

1. **Write Test (RED):**
   - Verify `VLCPlaybackController` reads `originProxy?.currentBufferedRanges()` during snapshot polling and passes it into `PlaybackSnapshot(..., bufferedRanges: ranges)`.
   - Verify episode switch clears buffer ranges immediately.
2. **Run Test:**
   - Execute: `xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/VLCPlaybackControllerTests`
   - Expected: RED.
3. **Minimal Implementation (GREEN):**
   - Update `VLCPlaybackController.pollPlaybackState()` to pull ranges from `originProxy`.
   - Ensure `stop()` or switching media resets the proxy ranges.
4. **Run Test:**
   - Re-run command; verify tests pass GREEN.

---

### Step 5: Update Scrubber UI & Disclaimer in `PlayerScreen.swift`
**Files:**
- Modify: `QuarkTheater/Views/PlayerScreen.swift`

1. **Implementation:**
   - In `PlayerScreen.swift` `seekHUDView`:
     - Keep the multi-range rendering in `GeometryReader` (`bufferedRanges`).
     - In accessibility and diagnostics labels, annotate the buffer display as `"网络已下载分片（近似缓冲）"` / `"Network-Fetched Segment Range (Approximation)"`.
     - When `bufferedRanges` is empty (e.g. direct MP4 or live stream), suppress multi-range bars cleanly without layout jitter.
2. **Manual / Diagnostic Verification:**
   - Verify compilation and view layout in simulator.

---

## 4. Risks and Edge Cases

1. **Variant Bitrate Switching:**
   - *Risk:* Changing HLS variant streams might have slight duration skew between representations.
   - *Mitigation:* The active variant segment table tracks the actively selected sub-playlist; timeline offsets are updated if a new variant is parsed.
2. **Memory Leaks from Long Streams:**
   - *Risk:* Parsing thousands of segments could grow unbounded.
   - *Mitigation:* Cap segment table to last 2,000 segments; cap coalesced range list to 50 items.
3. **UI Glitches on Non-VOD Streams:**
   - *Risk:* Sliding window manifests causing jumpy buffer bars.
   - *Mitigation:* Strictly suppress buffer ranges if `#EXT-X-ENDLIST` is absent.

---

## 5. Verification Commands

1. **Run Unit Tests:**
   ```bash
   xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/HLSTimelineParserTests -only-testing:QuarkTheaterTests/PlaybackRangeCoalescerTests -only-testing:QuarkTheaterTests/VLCOriginHTTPProxyBufferTests -only-testing:QuarkTheaterTests/VLCPlaybackControllerTests
   ```
2. **Project Integrity Check:**
   ```bash
   python3 scripts/generate_xcode_project.py --check
   ```
3. **Local Loopback Python Test:**
   ```bash
   python3 scripts/test_vlc_origin_proxy.py
   ```
