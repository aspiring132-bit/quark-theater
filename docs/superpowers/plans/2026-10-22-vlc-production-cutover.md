# VLC Production Playback Cutover Plan

**Goal:** Replace the production KSPlayer/Apple playback path with TVVLCKit (VLC) while keeping the existing `PlayerScreen` layout, drawer presentation, focus behavior, remote-control reducer, episode selection, subtitle/audio controls, seek HUD, diagnostics, and Quark resource resolution unchanged from the user’s point of view. The first delivery is simulator-only; it must not merge to `main`, install on the physical Apple TV, or add a user-visible engine switch.

**Architecture:** Keep `PlaybackCoordinator` as the single owner of queue/history/generation/retry/resource resolution. Introduce a neutral `PlaybackEngine` protocol and value types (`PlaybackResource`, `PlaybackTrack`, snapshot/events). Implement that protocol with a production `VLCPlaybackEngine` backed by one `VLCMediaPlayer` per active generation. `PlayerScreen` consumes only neutral coordinator state and renders a `VLCVideoSurface`; the drawer and focus tree remain in place. The existing Debug VLC page is not the production surface and must not become a second coordinator.

**Constraints:** Preserve all pre-existing dirty and untracked files unless a task explicitly owns them. Do not use `git add -A`, reset, checkout, or destructive cleanup. Do not change the app version in this cutover branch. Keep the Apple TV simulator `3B8F12B8-476E-4171-9665-F645F63D4660` as the only runtime target for validation. A missing `Frameworks/TVVLCKit.xcframework` must fail generation with a clear instruction to run `scripts/setup_vlc.sh` rather than silently generating a KS-only project.

## Phase 1 — Baseline and contracts (write tests first)

1. Inspect `PlaybackCoordinator.swift`, `PlayerScreen.swift`, `LiveQuarkClient.swift`, the existing VLC POC files, `scripts/generate_xcode_project.py`, and `Package.resolved`. Record the current public behavior and retain the existing worktree diff.
2. Add failing unit tests for a fake-engine coordinator before changing production behavior:
   - explicit episode selection starts the requested file exactly once;
   - a new generation cancels/ignores late events from the previous generation;
   - automatic next episode, history restore, retry, and end/error mapping remain coordinator responsibilities;
   - seek, pause/resume, and 10/15-second preferences are forwarded without changing drawer focus state;
   - audio/subtitle UI indexes map to actual engine track IDs, never array offsets;
   - a failed media switch cannot leave the previous frame attached as the new episode.
3. Define the neutral engine API in new files under `QuarkTheater/Playback/` (for example `PlaybackEngine.swift` and `PlaybackTypes.swift`). The contract must expose surface binding, load/play/pause/stop/seek, time/duration/buffer/network-rate snapshots, track discovery/selection, readiness/ended/error events, and diagnostic snapshots. Make event delivery generation-aware and main-thread safe.

**Verification:** Run the new targeted XCTest cases and confirm they fail for the missing contract before implementation. Keep the exact command and failure output in the handoff; do not call the phase complete merely because the project compiles.

## Phase 2 — Production VLC engine

1. Convert `QuarkTheater/Playback/VLC/VLCPlaybackController.swift` from a DEBUG-only POC into the sole `VLCPlaybackEngine` implementation. Remove its duplicate Quark client/resource resolution responsibility; the coordinator passes a fully resolved resource and allow-listed headers/cookies.
2. Bind a dedicated `VLCVideoSurface` (`UIView`/tvOS-compatible wrapper) to the active media player. On every episode switch, detach delegate/drawable/media from the old player, stop it, increment generation, create the new player/media, attach the new surface, and reject stale callbacks whose generation or media identity does not match.
3. Implement delegate-driven state/readiness/end/error events. Keep a bounded timer only for time, buffer and statistics snapshots. Include NSError/domain/message plus VLC state, media URL identifier, generation, has-video-output and audio-buffer/lost-buffer counters in existing diagnostics; redact cookies and query tokens.
4. Implement track discovery with a stable neutral model. Filter VLC’s synthetic “Disabled” audio item; map subtitle disabled to the existing “关闭字幕” row. Store the real VLC track ID in each `PlaybackTrack` and call VLC setters with that ID, not the SwiftUI list index. Preserve existing subtitle/audio labels and drawer behavior.
5. Preserve request requirements from `LiveQuarkClient`: cookies, User-Agent, Referer, and Origin. Verify against a real Quark playback URL whether TVVLCKit 3.7.2 can satisfy Origin/Range requests. Do not invent an `http-origin` option. If Origin is mandatory, stop the cutover at a tested request adapter/proxy boundary and document it rather than silently dropping the header.

**Verification:** Unit-test URL/header planning, track-ID mapping, generation cancellation, state transitions, and diagnostic redaction. Add a small local fixture containing video plus audio and subtitle tracks; the existing video-only fixture is insufficient. Run the targeted tests and a Debug simulator build.

## Phase 3 — Integrate without changing UI behavior

1. Update `PlaybackCoordinator` to depend on `PlaybackEngine`, retaining queue ordering, episode selection, history, retries, cancellation, playback-generation bookkeeping, and diagnostics. Remove direct KSPlayer types and callbacks.
2. In `PlayerScreen.swift`, replace only the KS video surface and KS-specific subtitle overlay with `VLCVideoSurface` and neutral track/snapshot bindings. Keep the drawer dimensions, episode cards, focus identifiers, accessibility labels, remote up/down/back/left/right handling, seek HUD, and hint lifecycle unchanged.
3. Route existing play/pause, short seek, long-press/continuous seek, next/previous episode, subtitle, audio, and close-drawer actions through coordinator/engine methods. Ensure a drawer back action closes the drawer before exiting the player and that focus returns to the previously focused control.
4. Remove the standalone “VLC 试播” debug entry point and `Views/Debug/VLCPlayerView.swift` once production coverage exists; do not leave a second playback path reachable in Release.

**Verification:** Run all existing PlayerScreen/remote UI tests plus the new engine tests. Assert that no KSPlayer/KSMEPlayer/KSAVPlayer import or symbol remains in production source. Use a source-level check to ensure the drawer and focus components remain present.

## Phase 4 — Project/dependency and legal packaging

1. Update `scripts/generate_xcode_project.py` so TVVLCKit is required and linked/embedded in Debug and Release; generation fails fast with the setup command when the XCFramework is absent.
2. Remove KSPlayer package/product/target dependencies and any KS-only package entries from `Package.resolved` that are not used elsewhere. Regenerate the project and inspect the diff; preserve unrelated version or branding edits already present.
3. Keep `scripts/setup_vlc.sh` pinned to the verified TVVLCKit release and SHA-256. Add/update `THIRD_PARTY_NOTICES.md` with VideoLAN/VLCKit LGPL-2.1-or-later notice, source-access instructions, and any local modifications. Have legal review confirm App Store/LGPL and codec obligations before release.

**Verification:** Run `python3 scripts/generate_xcode_project.py --check`, inspect generated project settings, and confirm Release does not link KSPlayer. Build Debug and Release for the simulator; verify the app bundle contains TVVLCKit and no KSPlayer framework/product.

## Phase 5 — Simulator acceptance and handoff

1. Boot simulator `3B8F12B8-476E-4171-9665-F645F63D4660`, install the newly built app, launch it, and capture a screenshot/log stream. Do not install or operate the physical “主卧” device.
2. Execute the acceptance matrix:
   - open a movie and a series episode from the poster wall;
   - open/close drawer repeatedly and verify focus/back behavior;
   - select non-adjacent episodes and verify title, active card, and actual media agree;
   - pause/resume, 10/15-second seek, repeated seek, and long press;
   - switch subtitle/audio tracks and disable subtitles;
   - exercise buffering, retry, end-to-next, history restore, and an invalid URL;
   - observe diagnostics for generation, VLC state, audio-buffer/lost-buffer, video-output and error details;
   - run at least a 30-minute local/accessible stream soak when a test URL is available.
3. Record every command, exit code, test result, simulator UDID, app build, unresolved limitation, and whether real Quark headers/Range were exercised. Explicitly state that simulator validation cannot prove HomePod/AirPlay routing or eliminate the physical-device mute issue.

## Completion gate

The cutover is ready for review only when Debug and Release simulator builds succeed, targeted and existing tests pass (or each failure is explained with evidence), no KS runtime path remains, Quark header behavior is verified or explicitly blocked, and the simulator acceptance matrix has a written result. No merge, push, version bump, or physical-device installation is part of this plan.
