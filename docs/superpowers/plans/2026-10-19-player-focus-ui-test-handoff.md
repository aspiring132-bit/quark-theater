# Player Focus UI Test Handoff Plan

> **For agentic workers:** Implement this plan on a test branch, task by task. Do not install or operate the physical Apple TV.

**Goal:** Prove that the actual player focus tree routes remote commands exactly once and that seek/play-pause remain correct before any merge to `main`.

**Architecture:** Keep `PlayerInputReducer` as the deterministic policy layer, and add tvOS UI tests that launch the real `PlayerScreen` focus hierarchy with a deterministic test playback session. The fixture must not contact Quark or TMDB or change normal app launch behavior. Tests must assert focus and action outcomes on the real controls, not a parallel mock screen.

**Tech Stack:** Swift, SwiftUI, XCTest/XCUITest, tvOS 27 Simulator, Xcode 27.

---

## Current Evidence and Constraints

- `QuarkTheater/Views/PlayerScreen.swift` owns `.onMoveCommand`, `.onPlayPauseCommand`, the drawer, and focus state.
- `QuarkTheater/Playback/PlayerInputReducer.swift` has unit coverage, but reducer tests do not prove tvOS Focus Engine routing.
- The project currently has a unit-test target but no UI-test target. `scripts/generate_xcode_project.py` is the project-generation source and must be updated if adding one.
- Simulator under test: Apple TV 4K (3rd generation), UDID `3B8F12B8-476E-4171-9665-F645F63D4660`.
- Recent `xcodebuild test` attempts failed before assertions with `DTServiceHubClient failed to bless service hub ... com.apple.instruments.deviceservice.lockdown`. This is an infrastructure failure, not a product-test pass/fail.
- `--mock-demo` exists, but `MockQuarkClient.playbackResource` throws. Do not assume it exercises an active player without an additional deterministic test seam.

## Files and Responsibilities

- Modify `scripts/generate_xcode_project.py` and regenerate `QuarkTheater.xcodeproj/project.pbxproj` only if a UI-test target is required.
- Modify `QuarkTheater/Views/PlayerScreen.swift` only for stable accessibility identifiers or a narrow test injection seam; retain the production focus tree and event route.
- Modify `QuarkTheater/Playback/PlayerInputReducer.swift` only if tests expose a policy defect; native tvOS focus remains the sole owner of drawer horizontal movement.
- Add `QuarkTheaterUITests/PlayerRemoteInteractionTests.swift` (or the test source directory required by the generator).
- Add unit tests under `QuarkTheaterTests/` only for pure behavior not observable through UI tests.

## Tasks and Acceptance

### Task 1: Deterministic UI-test entry point

- [ ] Add a test-only launch argument/injection seam that presents the actual player screen with a deterministic playback session and known drawer entries. No credentials, Quark calls, or TMDB calls; normal production launch is unchanged.
- [ ] Register the UI-test target in the project generator and generated project. Confirm `xcodebuild -list -project QuarkTheater.xcodeproj` reports the intended targets/scheme.
- [ ] Add stable accessibility identifiers for drawer trigger, tabs, episode cards, seek feedback/time, and play/pause state. Do not expose real account/file IDs or sensitive labels.

### Task 2: Remote interaction regression tests

- [ ] Test the actual `PlayerScreen` hierarchy:
  - Drawer closed: one left/right press changes playback time by exactly the configured 10/15 seconds.
  - Drawer open: one left/right press moves focus by exactly one adjacent target and leaves playback time unchanged.
  - After the hint fades: one down press opens the drawer.
  - Play/pause command toggles the observable playback state.
  - Closing the drawer restores a valid visible focus target.
- [ ] Assert both focused control identity and side effect. Reducer-only tests or selected-tab state alone do not satisfy this task.
- [ ] Repeat the focus-step UI tests at least three times to detect nondeterministic focus routing.

### Task 3: Simulator run

```bash
DEVELOPER_DIR=/Applications/Xcode_27_beta_6.app/Contents/Developer \
xcodebuild test -project QuarkTheater.xcodeproj -scheme QuarkTheater \
  -destination 'id=3B8F12B8-476E-4171-9665-F645F63D4660' \
  -parallel-testing-enabled NO \
  -only-testing:QuarkTheaterUITests/PlayerRemoteInteractionTests \
  CODE_SIGNING_ALLOWED=NO
```

- [ ] If service-hub/test-worker failure recurs, attach the exact error and `xcresult` summary; do not label tests passed and do not merge to `main`.
- [ ] On a healthy runner, record test counts/results and simulator screenshots for one-step movement and post-hint drawer opening.
- [ ] Manually repeat the same matrix using the Simulator remote only. Physical Apple TV testing is out of scope for this handoff.

**Return package:** Test branch name and commit hash; changed-file list; exact build/test commands and outputs; `xcresult` summary; screenshots; known limits. Do not merge or push `main`; return results for review/alignment.

