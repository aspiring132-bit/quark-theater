# Playback Reliability and Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent confirmed episode-selection/player-session mismatches and make playback, focus, and A/V anomalies traceable without logging credentials or signed URLs.

**Architecture:** Keep the selected cloud file identity authoritative from queue construction through URL resolution and KSPlayer state. Switch media through the already-mounted KSPlayer layer, keeping the active file unchanged until the new resource is validated. Extend allowlisted diagnostics with opaque playback correlation, queue/focus ordinals, actual engine, player state, A/V sync difference, and dropped-frame metrics.

**Tech Stack:** Swift, SwiftUI/tvOS 27, KSPlayer 2.3.4, XCTest, Xcode simulator.

---

### Task 1: Make episode queue ordering use canonical metadata

**Files:**
- Modify: `QuarkTheater/Views/MediaLibraryScreen.swift`
- Modify: `QuarkTheater/Views/MediaItemDetailScreen.swift` (preserve the user's current unassigned-season edits)
- Test: `QuarkTheaterTests/CodexUpdateTests.swift` or a focused new queue test file

- [ ] Add a failing test proving confirmed season/episode metadata wins over stale filename parsing and unresolved episodes are not mislabeled as episode 1.
- [ ] Run the focused test and verify the expected assertion fails.
- [ ] Implement one canonical episode-number projection for sorting/display; keep unresolved items outside numbered auto-play order.
- [ ] Run the focused test and verify it passes.

### Task 2: Make episode changes preserve file/player identity

**Files:**
- Modify: `QuarkTheater/Playback/PlaybackCoordinator.swift`
- Modify: `QuarkTheater/Views/PlayerScreen.swift`
- Test: playback coordinator tests

- [x] Add deterministic tests for delayed/mismatched resource resolution: active file identity is accepted only when generation, pending file, and `PlaybackResource.fileID` all agree.
- [x] Implement generation-safe pending selection; keep the mounted KSPlayer coordinator and apply a validated URL through `KSPlayerLayer.set(url:options:)`.
- [x] Bind state callbacks to the matching session/generation and keep retry responses tied to the original selected file.
- [x] Pause and detach callbacks from the previous player immediately on a real episode switch, preventing the old frame/audio from surviving while the next resource resolves.
- [ ] Run focused tests, then the playback test suite (blocked by the tvOS simulator service; see Task 4).

### Task 3: Add useful, privacy-safe playback and focus diagnostics

**Files:**
- Modify: `QuarkTheater/Core/DiagnosticsStore.swift`
- Modify: `QuarkTheater/Core/Diagnostics.swift`
- Modify: `QuarkTheater/Playback/PlaybackCoordinator.swift`
- Modify: `QuarkTheater/Views/PlayerScreen.swift`
- Test: diagnostics store and focus navigation tests

- [ ] Add failing serialization/projection tests for allowlisted focus ordinals, playback session correlation, engine kind, A/V sync delta, and dropped-frame count.
- [ ] Run focused tests and verify the new fields are not currently supported.
- [ ] Record selection/resolution/start/state/seek/finish/error transitions under an opaque correlation ID; record only URL host at most, never the full signed URL, cookies, account ID, or raw cloud file ID.
- [x] Sample KSPlayer state and dynamic sync metrics at a bounded 15-second interval while playing; emit immediately on player-state, audio-track, or audio-route changes. Stop the heartbeat on pause, stop, or view disappearance. Log the actual KSAVPlayer/KSMEPlayer type instead of a fixed FFmpeg label. Never persist IDs, titles, URLs, cookies, raw errors, or claim automatic output-silence detection.
- [x] Keep horizontal drawer movement owned by the tvOS focus engine; the custom reducer only seeks when the drawer is closed. Keep the drawer trigger mounted after its hint fades so ▼ has a stable target.
- [x] Add deterministic reducer coverage proving drawer-left/right does not also issue a second custom movement action.
- [ ] Verify on tvOS that one remote left/right changes one focus ordinal, ▼ opens the drawer after the hint fades, and drawer navigation never seeks; simulator/device UI validation remains required.

### Task 4: Verify in tvOS 27 simulator

**Files:** no production changes.

- [ ] Run focused XCTest cases and the complete test target using `/Applications/Xcode_27_beta_6.app` and the tvOS 27 simulator.
- [ ] If the simulator test service again fails before tests start, record that as infrastructure failure, not a passing test.
- [ ] Build the app for tvOS 27 and inspect the final diff to ensure the four pre-existing user-modified files were preserved.
- [ ] Do not install or operate the physical Apple TV.
