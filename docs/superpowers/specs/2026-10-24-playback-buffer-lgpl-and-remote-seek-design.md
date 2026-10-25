# Design: Playback Buffered-Segment Display, Remote Long-Press Seeking, and Bundled TVVLCKit/LGPL Release Notice

**Date:** 2026-10-24
**Status:** Awaiting User Review (Outline approved; written spec pending review; implementation has not started)
**Target Path:** `docs/superpowers/specs/2026-10-24-playback-buffer-lgpl-and-remote-seek-design.md`

---

## 1. Context and Problem Statement

Quark Theater uses `TVVLCKit` (LibVLC 3.x) with a local loopback proxy (`VLCOriginHTTPProxy`) to stream HLS and direct-play media assets while honoring Quark-specific HTTP headers (`Origin`, `Referer`, `Cookie`, `User-Agent`). Three specific areas require architectural definition before implementation:

1. **Buffer Visual Feedback:** `TVVLCKit` does not expose fine-grained, accurate decoder-resident timeline buffer ranges to the playback controller. Currently, `VLCPlaybackController` populates `bufferedRanges: []` and supplies only basic time metrics. Users need visual feedback on network download progress, but conflating network fetches with LibVLC decoder-resident audio/video presentation frames would cause false expectations during stalls or clock discontinuities. Furthermore, this network-fetched buffer approximation is scoped strictly to VOD HLS streams for this implementation; direct MP4 and live/sliding playlists must not show fabricated ranges unless a stable timeline mapping is available.
2. **Remote Navigation and Long-Press Seeking:** Currently, seeking relies on discrete `.onMoveCommand` callbacks in `PlayerScreen.swift` with an ad-hoc timer-based repeat counter (`now.timeIntervalSince(lastSeekDate) < 0.45`). This repeated onMoveCommand heuristic is brittle, does not differentiate between held directional presses and rapid discrete clicks, cannot cleanly capture press-up/release transitions without artificial timeout delays, and risks interfering with drawer focus navigation when focus shifts.
3. **Open-Source Compliance Documentation:** The project bundles `TVVLCKit.xcframework`. The VideoLAN VLCKit project is declared LGPL version 2.1 (do not claim or-later unless archive license proves it), while bundled modules and third-party dependencies remain conditional on an archive inventory. A formal release notice must accompany binary distributions, presenting exact version metadata, LGPL text, source code availability, and instructions for re-linking/swapping the framework, without asserting legal compliance guarantees.

### Explicit Scope Exclusions (Per User Direction)
- **Excluded:** Any episode title display modifications or current-playing badge UI changes.
- **Excluded:** Pushing branches or commits to any GitHub remote repository (local commits are not prohibited).
- **Excluded:** Modifying application code or test files in this design step.

---

## 2. Topic 1: Approximate HLS Buffered-Segment Display (VOD HLS Scoped)

### 2.1 Scope & Network-Fetch Approximation Principle and Disclaimer
The player UI scrubber will display a secondary buffer bar representing network-fetched segment spans strictly scoped to **VOD HLS streams** for this implementation.

- **Direct MP4 Playback:** Direct MP4 playback does not utilize segment-based manifest parsing, and raw byte-range reads over loopback do not map directly to presentation time without container moov/stbl box inspection. Therefore, direct MP4 playback must not show fabricated ranges unless a stable timeline mapping is available.
- **Live / Sliding-Window HLS Playlists:** Sliding manifests dynamically change segment availability windows and sequence offsets. Live or sliding playlists must not display fabricated ranges unless a stable timeline mapping is available.
- **VOD HLS Streams:** Scoped exclusively to VOD HLS streams where complete playlist manifests (`#EXT-X-ENDLIST`) define static, deterministic segment sequence mappings to playback presentation time.

> **Architectural Boundary & Labeling Requirement:**
> This buffer representation is explicitly defined and labeled in UI and diagnostics as **"网络已下载分片（近似缓冲）" / "Network-Fetched Segment Range (Approximation)"**, **not** a guarantee of LibVLC decoder-resident frames ready for immediate presentation. LibVLC maintains internal demuxer, packet, and audio/video output FIFO buffers whose exact millisecond boundaries are opaque across the public TVVLCKit API.

### 2.2 Ingestion via `VLCOriginHTTPProxy`
All VOD HLS media playlist and segment network traffic flows through the local `VLCOriginHTTPProxy`. The proxy observes downstream requests from TVVLCKit and fetches upstream responses from Quark CDN.

```
+-----------------------------------------------------------------------------------+
|                              VLCOriginHTTPProxy                                   |
|                                                                                   |
|  Master Playlist -> Selected Variant Playlist (.m3u8, VOD)                        |
|                           |                                                       |
|                           v                                                       |
|                 Segment Index Parser                                              |
|      (EXTINF Durations, Byte Ranges, Discontinuity Sequences)                     |
|                           |                                                       |
|                           +--- If Direct MP4 or Live/Sliding (No stable mapping)  |
|                           |    -> bufferedRanges remains [] (suppressed)          |
|                           v                                                       |
|             Active Variant Segment Timeline Table (VOD HLS Only)                  |
|                           |                                                       |
|                           +<--- Upstream 200/206 Complete Responses               |
|                           |     (Filtered for Request Generation Match)           |
|                           v                                                       |
|             Completed Segment Time Ranges [CMTimeRange]                           |
|                           |                                                       |
|                           v (Coalesced / Normalized)                              |
+---------------------------+-------------------------------------------------------+
                            |
                            v MainActor Dispatch
+-----------------------------------------------------------------------------------+
| PlaybackCoordinator -> PlayerScreen Scrubber (Buffered-Range Visual Layer)        |
+-----------------------------------------------------------------------------------+
```

### 2.3 Detailed Ingestion and Timeline Rules

1. **VOD Stream Scope Enforcement:**
   Timeline assembly activates only when the proxy identifies a VOD playlist manifest (or playlist terminating with `#EXT-X-ENDLIST`). For non-VOD streams (live/sliding playlists) or direct MP4 streams, the proxy emits an empty range set (`[]`) to prevent displaying fabricated or misaligned buffer bars unless a stable timeline mapping is available.
2. **Variant Selection Tracking:**
   When the player loads a master playlist (`#EXT-X-STREAM-INF`), the proxy rewrites URLs to loopback routes. Observing a playlist request alone does not by itself prove that the selected variant is actively playing. The proxy must preserve the playlist-to-segment mapping and scope the buffer range estimate strictly to segment URIs that are actually requested and completed. Because variant switches and discontinuity sequence alignments across bitrate shifts may cause duration or sequence misalignment, this alignment behavior requires targeted test verification.
3. **`EXTINF` Timeline & Time-Range Assembly:**
   Each segment listed under `#EXTINF:<duration>` possesses an implicit or explicit timeline offset:
   - $T_0 = 0.0$ (or program date-time base).
   - $T_i = \sum_{k=0}^{i-1} \text{Duration}_k$.
   - Segment $i$ corresponds to timeline interval $[T_i, T_i + \text{Duration}_i)$.
   The range estimate is strictly scoped to segment URIs that have actually been requested and completed upstream rather than inferring coverage from playlist manifest availability alone.
4. **Byte-Range Segments (`EXT-X-BYTERANGE`):**
   If a variant utilizes sub-range requests (`@offset` or length-only), a segment is marked completed *only* when the exact matching byte range request returns HTTP status `206 Partial Content` (or `200 OK` for full resources) and the proxy reads the final byte without truncation or early socket reset.
5. **HLS Discontinuities (`EXT-X-DISCONTINUITY`):**
   Discontinuities indicate timestamp resets or codec transitions. The proxy maintains discontinuity sequence numbers (`discSeq`). Segments within distinct discontinuity sequences are mapped along the continuous playback presentation timeline using cumulative segment durations, matching TVVLCKit's continuous timeline playback.
6. **Request Generation Counter:**
   Each play or switch operation increments a 64-bit integer `playbackGeneration`. Segments in flight from a previous generation that complete late are discarded and never merged into the active buffer state.
7. **Seek and Episode-Switch Reset:**
   - **Episode Switch:** Completely purges segment registries, playlist maps, and buffered intervals.
   - **Seek within Same Item:** Does not discard previously downloaded segments if they remain valid in the variant playlist; it continues appending newly downloaded segments around the new playhead target.
8. **Partial and Failed Responses:**
   If an upstream connection is dropped, timed out, cancelled by LibVLC, or returns an HTTP status $\ge 400$, the segment is discarded. No partial duration fraction is added to the completed range.
9. **Bounded Memory and State Cap:**
   To prevent memory leaks during long-running playback:
   - Playlist entries are capped at the last 2,000 segments.
   - Contiguous ranges are merged immediately: if Range $A = [0, 10]$ and Range $B = [10, 20]$, they merge into $[0, 20]$.
   - The coalesced range list is capped at a maximum of 50 non-contiguous segments/gaps (discarding ranges furthest from the current playback head if bounded capacity is reached).

---

## 3. Topic 2: Long-Press Left/Right Remote Seeking

### 3.1 Deficiencies of Current Implementation
The current implementation in `PlayerScreen.swift`:
```swift
// Current repeated heuristic in PlayerScreen.swift
let isRepeat = lastSeekDirection == dir && (lastSeekDate.map { now.timeIntervalSince($0) < 0.45 } ?? false)
seekRepeatCount = isRepeat ? min(seekRepeatCount + 1, 4) : 0
...
seekCommitTask = Task { @MainActor in
    try? await Task.sleep(nanoseconds: 450_000_000)
    ...
    coordinator.seek(to: target)
}
```
Problems:
- Relies on system-generated move-repeat pacing that varies across tvOS versions.
- Lacks a deterministic key-down / key-up press lifecycle.
- Cannot cleanly abort acceleration if the user lifts their finger immediately.
- Traps left/right navigation within the move command handler, creating conflict risks if the drawer is active.

### 3.2 Target Long-Press Remote Lifecycle Architecture

#### Investigated tvOS Remote Event APIs
1. **`SwiftUI .onLongPressGesture` / `SpatialTapGesture`:**
   Unreliable on Apple TV Siri Remote directional clicks; does not capture continuous hold durations or release events for the directional ring.
2. **`SwiftUI .onMoveCommand`:**
   High-level focus navigation callback. Fires repeatedly when held, but does not provide release callbacks, resulting in a mandatory trailing timeout delay before committing.
3. **`tvOS Press Lifecycle (UIPress / GCController / UIResponder)`:**
   - `UIPress.PressType.leftArrow` and `UIPress.PressType.rightArrow` on a backing custom `UIView` or `UIHostingController` subclass.
   - Hypothesis to verify on target tvOS versions: Siri Remote clickpad directional presses and `pressesBegan`/`pressesEnded` lifecycle events are assumed to map cleanly to `UIPress` directional events when playback focus is frontmost. This cannot be asserted unconditionally without hardware and target OS verification, as Siri Remote interactions (touch vs. click) and tvOS focus engine interactions may swallow or alter release events.
   - Fallback and Stop Condition: If target tvOS versions or hardware remotes do not expose reliable release events (`pressesEnded`/`pressesCancelled`) or fail to map directional clicks to `UIPress`, the system falls back to a bounded heartbeat/cooldown stop condition: seeking ceases automatically if no subsequent press/repeat event is detected within a defined timeout threshold (e.g., 400ms), committing the accumulated seek target safely without trapping the player in an infinite seek loop.

#### Selected Architecture: Dedicated Playback Press Interceptor
A lightweight, transparent `UIViewRepresentable` (`RemotePressGestureReceiver`) will be attached to `PlayerScreen` exclusively when the drawer is closed and video playback is frontmost.

```
       [Siri Remote Directional Left/Right]
                         |
                         v
       [RemotePressGestureReceiver (UIResponder)]
          |              |                 |
     pressesBegan  pressesChanged    pressesEnded / Cancelled
          |              |                 |
          +--------------+-----------------+
                         |
                         v
       [PlayerRemoteSeekStateReducer]  <-- Pure functional state machine
                         |
         +---------------+---------------+
         |                               |
         v                               v
[Step Acceleration Timer]       [PlayerSeekMath]
   Tier 1: 1x (0.0s - 1.0s)        Accumulates pendingSeekTarget
   Tier 2: 2x (1.0s - 2.5s)        Clamps to [0, duration]
   Tier 3: 4x (2.5s - 5.0s)        Updates seek HUD state
   Tier 4: 8x (> 5.0s)
                         |
                         v (Upon pressesEnded)
       [Coordinator Commit: seek(to: finalTarget)]
```

### 3.3 State Machine and Acceleration Policy
The seek lifecycle operates under `PlayerRemoteSeekStateReducer`:
- **Press Began (`.began`):**
  - Record timestamp `pressStartTime`.
  - Execute immediate single-step seek using configured skip interval (`PlayerSeekPreference.current`, 10s or 15s).
  - Start seek repeat timer (ticks every 250ms).
- **Timer Tick (`.held`):**
  - Calculate elapsed hold time: $\Delta t = t_{\text{tick}} - t_{\text{start}}$.
  - Determine acceleration tier:
    - **Tier 1 (0.0s – 1.0s):** $1\times$ configured interval (e.g. 10s per step).
    - **Tier 2 (1.0s – 2.5s):** $2\times$ configured interval (e.g. 20s per step).
    - **Tier 3 (2.5s – 5.0s):** $4\times$ configured interval (e.g. 40s per step).
    - **Tier 4 (> 5.0s):** $8\times$ configured interval (e.g. 80s per step).
  - Update `pendingSeekTarget = clamp(pendingSeekTarget ± stepInterval, 0, duration)`.
  - Update HUD display (showing directional indicator, accumulated target, and acceleration tier multiplier: `1x`, `2x`, `4x`, `8x`).
- **Press Ended / Cancelled (`.ended` / `.cancelled`):**
  - Invalidate hold timer immediately.
  - Dispatch single final commit seek to `coordinator.seek(to: pendingSeekTarget)`.
  - Reset press lifecycle state.
- **Drawer Isolation:**
  When `isDrawerOpen == true`, `RemotePressGestureReceiver` disables user interaction and ignores directional arrow presses, returning focus navigation completely to standard SwiftUI focus engines for tab and episode list navigation.

### 3.4 Verification Requirements
- **Automated Tests:** Unit tests for `PlayerRemoteSeekStateReducer` validating:
  - Immediate initial step matches configured skip interval.
  - Multi-tier acceleration thresholds based on elapsed wall-clock timestamps.
  - Clamping at zero and end of stream.
  - Release cancels timers and produces an immediate seek command without duplicate commits.
- **Simulator & Hardware Test Suite:**
  - Hardware: Apple TV 4K with Siri Remote (USB-C / Lightning generation).
  - Simulator: tvOS 27 Simulator using Mac arrow keys and Simulated Remote (Menu, Directional Pad).

---

## 4. Topic 3: TVVLCKit / LibVLC LGPL Release Notice and License Inventory

### 4.1 Legal & Open-Source Integrity Policy
Quark Theater bundles pre-compiled binary builds of `TVVLCKit.xcframework`. The VideoLAN VLCKit project is declared LGPL version 2.1 (do not claim or-later unless archive license proves it), while bundled modules and third-party dependencies remain conditional on an archive inventory. Documentation must not claim all bundled core modules share a single uniform license until a full inventory of the downloaded distribution archive is performed.

> **Notice Regarding Legal Claims:**
> This specification and associated documentation do **not** assert or guarantee formal legal compliance. Compliance with the GNU Lesser General Public License is an ongoing organizational and engineering obligation. The software documentation must accurately state what is bundled, provide the full license text, and offer clear mechanisms for source code inspection and framework re-linking.

### 4.2 Exact Bundled Version Inspection Requirement
All claims regarding the exact version of the bundled framework are tied directly to the archive pin in `scripts/setup_vlc.sh`, and exact license conclusions remain conditional on inspecting the downloaded archive:
- The authoritative download URL and pinned archive are defined in `scripts/setup_vlc.sh`:
  - Distribution URL: `https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz`
  - Version pin: `3.7.2` (as pinned in `setup_vlc.sh`; note that the binary framework's `Info.plist` may report generic bundle version `1.0` or `CFBundleShortVersionString` `1.0`).
  - Git commit hash reference: `3e42ae47`
  - Expected SHA256: `fa264c2eb17d648669d9d12b51e76e5b6769828354517d09b340387b30825f58`
- **Archive-Level License Inventory Requirement:**
  Exact license conclusions remain conditional on inspecting the downloaded archive itself. Before finalizing notices in `THIRD_PARTY_NOTICES.md`, the implementation must inspect the upstream archive license files (`COPYING`, `COPYING.LIB`, module-level licenses) and identify relevant bundled modules/licenses and source access terms. Do not claim that all bundled core modules have one blanket license until this archive-level inspection is completed.

### 4.3 Documentation and Release Artifact Additions
The existing `THIRD_PARTY_NOTICES.md` already contains notices for other project components (including references to QuarkPan under the MIT License and quarkpan-rs reference checks). It **must be appended to, not replaced**, ensuring all existing MIT and Quark client references are fully preserved.

The appended TVVLCKit section in `THIRD_PARTY_NOTICES.md` must include:
1. **Component Name & Version:** TVVLCKit 3.7.2 (LibVLC 3.0.x core, tied to `scripts/setup_vlc.sh` archive pin).
2. **License Declaration & Inventory Summary:**
   - VideoLAN VLCKit project declaration under LGPL version 2.1 (do not claim or-later unless archive license proves it).
   - Bundled modules and third-party dependencies remain conditional on an archive inventory.
3. **Full License Text:** Verbatim copy of LGPL-2.1 included in `THIRD_PARTY_NOTICES.md` or as a companion `LICENSES/LGPL-2.1.txt`.
4. **Source Code Access:**
   - VideoLAN VLCKit repository: `https://code.videolan.org/videolan/VLCKit`
   - Upstream LibVLC core source: `https://code.videolan.org/videolan/vlc`
   - Archive download source: `https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz`
   - Complete build and download scripts used in this repository (`scripts/setup_vlc.sh`).
5. **Re-linking / Framework Replacement Instructions:**
   Step-by-step instructions explaining how a recipient can replace `Frameworks/TVVLCKit.xcframework` with their own custom-built version and re-link the application using `python3 scripts/generate_xcode_project.py`.

---

## 5. Acceptance Criteria

| ID | Category | Requirement |
|---|---|---|
| **AC-BUF-01** | Buffer Display | Scrubber displays network-fetched segment intervals derived from `VLCOriginHTTPProxy` scoped strictly to VOD HLS streams. |
| **AC-BUF-02** | Buffer Disclaimer | UI and diagnostics explicitly characterize buffer as network-downloaded approximations, not decoder-resident frames. |
| **AC-BUF-03** | Buffer Precision | Segments are registered only upon 200/206 completion with matching byte ranges and request generations. |
| **AC-BUF-04** | Buffer Resets | Episode switch purges all segment buffers; seeks retain valid pre-downloaded ranges of the current item. |
| **AC-BUF-05** | Buffer Bounds | Memory bounds prevent unbounded growth (max 2,000 segments, max 50 coalesced ranges). |
| **AC-BUF-06** | Buffer Scope Guard | Direct MP4 playback and live/sliding playlists suppress fabricated range indicators and emit empty ranges unless a stable timeline mapping is available. |
| **AC-SEEK-01**| Remote Seek | Initial press immediately shifts position by configured interval (10s or 15s). |
| **AC-SEEK-02**| Remote Seek | Sustained press triggers multi-tier acceleration (1x, 2x, 4x, 8x). |
| **AC-SEEK-03**| Remote Seek | Releasing remote stops hold timers and immediately dispatches single final seek commit. |
| **AC-SEEK-04**| Remote Seek | Drawer navigation is unaffected when open; left/right focus within drawer operates normally. |
| **AC-SEEK-05**| Remote Seek | Reducer unit test suite verifies state transitions and acceleration math. |
| **AC-LGPL-01**| Compliance Docs | Version claims are tied to `scripts/setup_vlc.sh` archive pin (3.7.2, commit hash `3e42ae47`). VideoLAN VLCKit project is declared LGPL version 2.1 (do not claim or-later unless archive license proves it); bundled modules remain conditional on archive inventory. |
| **AC-LGPL-02**| Compliance Docs | `THIRD_PARTY_NOTICES.md` is appended to without replacing existing MIT and Quark client notices, incorporating full LGPL-2.1 text without asserting legal compliance guarantees. |
| **AC-LGPL-03**| Compliance Docs | Clear instructions provided for swapping and re-linking the XCFramework using project generation scripts. |
| **AC-SCOPE-01**| Scope Guard | No modifications made to episode title display or current-playing badge UI. |
| **AC-SCOPE-02**| Scope Guard | No push to any GitHub remote; local commits are not prohibited by the user. |

---

## 6. Unknowns, Edge Cases, and Technical Risks

1. **LibVLC Seeking Past Network Buffer:**
   *Risk:* LibVLC may issue non-sequential range or segment requests when seeking near boundary edges, causing temporary display jitter in the approximation bar.
   *Mitigation:* Coalesce adjacent ranges with a tolerance epsilon ($\le 0.1\text{s}$) and ensure the playhead indicator remains decoupled from the buffer range bar.
2. **Apple TV Remote Event Interception in SwiftUI:**
   *Risk:* In tvOS 17/18/27, mixing `UIViewRepresentable` responder chain hooks with SwiftUI focus environments can occasionally drop arrow release events if focus unexpectedly shifts during the press.
   *Mitigation:* Explicitly handle `.cancelled` in `pressesEnded`/`pressesCancelled` and bind the responder view's focusability strictly to the player viewport.
3. **Dynamic Variant Playlist Switching:**
   *Risk:* Quark CDN HLS streams may serve variant playlists with slight differences in segment duration rounding (e.g. 6.006s vs 6.000s).
   *Mitigation:* The proxy indexer tracks cumulative segment offsets based on the actively streamed variant file rather than attempting to synthesize a universal cross-variant clock.
4. **tvOS App Sandbox & Dynamic Re-linking:**
   *Risk:* While LGPL-2.1 permits dynamic framework replacement, tvOS code signing requires re-signing the application bundle with a developer profile whenever an embedded framework is replaced.
   *Mitigation:* Document the exact code-signing and Xcode re-generation steps required for independent framework substitution.

---

## 7. Implementation Plan & Affected File Paths (Preview)

> Implementation has **not** started. The following file paths are identified for subsequent implementation tasks:

- `QuarkTheater/Playback/VLC/VLCOriginHTTPProxy.swift` (segment parsing, VOD scoping, and timeline tracking)
- `QuarkTheater/Playback/PlaybackTypes.swift` (buffered range models)
- `QuarkTheater/Playback/VLC/VLCPlaybackController.swift` (plumbing proxy ranges into playback snapshots)
- `QuarkTheater/Playback/PlayerRemoteSeekStateReducer.swift` (new pure functional state machine)
- `QuarkTheater/Views/PlayerScreen.swift` (scrubber buffer bar & press interceptor integration)
- `QuarkTheater/Views/RemotePressGestureReceiver.swift` (new UIKit responder bridge for tvOS directional presses)
- `THIRD_PARTY_NOTICES.md` (append TVVLCKit LGPL notices, license inventory findings, and relink documentation while preserving existing notices)
- `QuarkTheaterTests/PlayerRemoteSeekStateReducerTests.swift` (new automated test suite)
- `QuarkTheaterTests/VLCOriginHTTPProxyBufferTests.swift` (new proxy timeline tests)
