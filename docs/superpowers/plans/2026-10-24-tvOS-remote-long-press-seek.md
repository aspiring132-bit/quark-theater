# Implementation Plan: tvOS Remote Long-Press Seeking Architecture

- **Date:** 2026-10-24
- **Target Path:** `docs/superpowers/plans/2026-10-24-tvOS-remote-long-press-seek.md`
- **Design Reference:** `docs/superpowers/specs/2026-10-24-playback-buffer-lgpl-and-remote-seek-design.md` (Topic 2: Section 3 & AC-SEEK-01..05)
- **Status:** Completed (Phase 0 Spike & Unit Verification)

---

## 1. Goal and Bounded Scope

Replace the fragile timer-heuristic seeking (`onMoveCommand` repeat counting with ad-hoc intervals) with a deterministic, accelerated seek architecture using a pure functional state machine (`PlayerRemoteSeekStateReducer`), while strictly preserving drawer focus isolation.

### Phase 0 Feasibility Gate & tvOS SDK Findings:
1. **SwiftUI `.onKeyPress` Limitation:**
   - Apple documentation and the tvOS 27 SDK header inspect confirm that SwiftUI `.onKeyPress` is designed for hardware keyboard input and does not intercept standard directional clicks from the Siri Remote.
2. **UIKit `pressesBegan` / `pressesEnded` via Transparent Receiver:**
   - Adding an unverified transparent `UIViewRepresentable` receiver in the tvOS focus tree risks breaking focus containment, being swallowed by focus guides/engines, or suffering missing `pressesEnded`/`pressesCancelled` events on remote clickpad releases.
3. **Production Input Mechanism:**
   - The only reliable production signal delivered to `PlayerScreen` across tvOS navigation layers remains the sequence of repeated `.onMoveCommand` callbacks.
   - Therefore, the smallest safe and robust architecture is a **pure deterministic reducer** (`PlayerRemoteSeekReducer`) driving `PlayerScreen.handleMoveCommand`.
4. **Hardware Verification Limitation:**
   - On physical Siri Remotes, if holding the left/right clickpad does not generate continuous repeated `.onMoveCommand` events from the operating system focus engine, hold acceleration cannot trigger in hardware without firmware-level repeat events. This remains an identified hardware/OS verification boundary, but every delivered repeated event accelerates deterministically according to spec.

### Acceleration & Commit Policy:
- **Base Step:** First press uses configured interval (10s or 15s from user preference) at $1\times$.
- **Sustained Hold Acceleration Tiers:**
  - Tier 1 ($0.0\text{s} - 1.0\text{s}$): $1\times$ configured interval
  - Tier 2 ($1.0\text{s} - 2.5\text{s}$): $2\times$ configured interval
  - Tier 3 ($2.5\text{s} - 5.0\text{s}$): $4\times$ configured interval
  - Tier 4 ($> 5.0\text{s}$): $8\times$ configured interval
- **No Timer-Tick Multiplications:** Multipliers apply strictly per actual remote event received. Internal timers/heartbeats never advance targets or invent synthetic seeks.
- **Commit & Timeout:** A bounded idle timeout ($450\text{ms}$) commits the pending target via `coordinator.seek(to:)` exactly once and resets the active session.
- **Drawer Isolation:** When the drawer is open (`showDrawer == true`), `PlayerInputReducer` drops horizontal movements (`.none`), keeping native focus intact and the seek reducer completely idle.

---

## 2. Architecture and Data Flow

```
                      [Siri Remote Left / Right]
                                   |
                                   v
                   +--------------------------------+
                   |  Drawer Open? (showDrawer)     |
                   +---------------+----------------+
                                   |
                YES                | NO
                 v                 v
    [SwiftUI Native Focus Engine]  [.onMoveCommand (direction)]
    (Navigate Tabs & Episodes)     |
                                   v
                   [PlayerInputReducer.reduce] -> .seek(dir, interval)
                                   |
                                   v
                   [PlayerRemoteSeekReducer.handle(state, event, ...)]
                      - Event: .playerMove(direction, timestamp)
                      - Tiers evaluated against session elapsed time:
                        - Tier 1: 1x (0 - 1.0s)
                        - Tier 2: 2x (1.0 - 2.5s)
                        - Tier 3: 4x (2.5 - 5.0s)
                        - Tier 4: 8x (> 5.0s)
                      - Clamps to [0, duration]
                                   |
                                   v (On 450ms Idle Timeout Task)
                   [PlayerRemoteSeekReducer.handle(state, .idleTimeout, ...)]
                      - Emits shouldCommit: true, commitTarget
                                   |
                                   v
                   [PlaybackCoordinator.seek(to: target)]
```

---

## 3. TDD Implementation & Verification

### Implemented Files:
- `QuarkTheater/Playback/PlayerRemoteSeekStateReducer.swift`: Pure deterministic reducer, acceleration policy, state & result contracts.
- `QuarkTheaterTests/PlayerRemoteSeekStateReducerTests.swift`: Comprehensive unit tests covering single press base interval, multi-tier acceleration ($1\times, 2\times, 4\times, 8\times$), idle gap session restart, direction change handling, boundary clamping, exactly-once commit, drawer suppression, and timer tick non-invention.
- `QuarkTheater/Views/PlayerScreen.swift`: Integrated `PlayerRemoteSeekState` and `PlayerRemoteSeekReducer` into `handleMoveCommand` and visual seek HUD indicator.
- `docs/superpowers/plans/2026-10-24-tvOS-remote-long-press-seek.md`: Documented implementation against actual tvOS SDK facts and hardware constraints.

### Test Results:
- `PlayerRemoteSeekStateReducerTests`: 10 passed, 0 failures on Apple TV Simulator (`3B8F12B8-476E-4171-9665-F645F63D4660`).
- `FocusNavigationTests`: 15 passed, 0 failures.
- Xcode Project generator consistency verified (`python3 scripts/generate_xcode_project.py --check`).
