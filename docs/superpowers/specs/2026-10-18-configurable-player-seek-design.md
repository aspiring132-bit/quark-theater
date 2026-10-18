# Configurable player seek design

## Goals

- Add a Settings choice for one directional skip interval: 10 or 15 seconds, defaulting to 10 seconds.
- Apply the same configured interval to both left/backward and right/forward Siri Remote seeks.
- Preserve the existing AVPlayer-based playback path, native video/decode surface, and native speed-hold behavior at 2x/3x/4x.
- Verify on tvOS 27 that native Siri Remote left/right events are intercepted reliably by the player and use the configured interval.

## Non-goals

- No duration-dependent long-hold seeking in this milestone.
- No replacement of the entire player UI if AVKit cannot reliably route skip commands through the configured interval; that limitation must be surfaced for a product decision.
- No change to native playback speed controls, playlist/episode behavior, buffering, subtitle/audio selection, or the user-directed silent-audio issue.

## Current-code constraints and affected modules

`RootView.swift` owns the existing `SettingsScreen` and its `@AppStorage` preferences. `PlayerScreen.swift` renders `VideoPlayer`, currently has two move-command handlers, and shows seek HUD state but does not apply a configurable seek operation. `PlaybackCoordinator.swift` owns the AVPlayer instance and is the appropriate boundary for clamped seek commands. The change should add a small preference model/key and connect Settings → PlayerScreen → PlaybackCoordinator without replacing `VideoPlayer` or the AVPlayer resource setup.

## Architecture and data flow

1. Define a persisted skip preference with values `10` and `15`, default `10`. The stored representation must be stable (integer seconds or an equivalent versioned enum), account-independent unless product settings are later made account-specific.
2. Settings exposes a segmented picker labeled clearly as “跳过时长” with 10 秒 and 15 秒 options. Existing installations with no key read as 10; invalid/out-of-range stored values migrate to 10. The preference remains available before and after a player is created.
3. `PlayerScreen` reads the preference and routes left/right remote commands to one command path. Left requests `currentTime - interval`; right requests `currentTime + interval`. The command path delegates to the coordinator, which clamps to zero and the loaded item duration when known, ignores non-finite times, and performs an AVPlayer seek with the existing async tvOS-compatible API.
4. The seek HUD continues to show direction/position feedback and uses the same command path for both directions. Repeated discrete presses may coalesce safely, but no press-and-hold duration algorithm is introduced.
5. The AVPlayer and `VideoPlayer(player:)` remain the playback/decode surface. Native speed-hold behavior remains owned by the system/AVKit integration; configurable skip is not implemented by replacing it with a custom transport UI.

There must be one authoritative left/right interception path. The current duplicate `.onMoveCommand` modifiers must be reconciled so navigation handling for the drawer does not accidentally consume or double-apply a seek. While the drawer is open, left/right focus navigation must retain its existing semantics unless tvOS 27 verification demonstrates that the native player event is the only reliable route; any such conflict is a documented trade-off, not a silent UI rewrite.

## Persistence and migration compatibility

Use the existing `@AppStorage`/UserDefaults preference mechanism with a new namespaced key. Existing settings are untouched. Missing key means 10 seconds; a future malformed value is repaired to 10 on read. No media catalog, watch-history, playback URL, cookie, or account migration is needed. The preference must not be written into watch history or shared playback state.

## Error and platform handling

- If the item is not ready or has no finite duration/current time, do not issue an invalid seek; keep playback state intact and provide the existing HUD/error affordance.
- Clamp beyond-start seeks to the item duration when available; clamp backward seeks to zero.
- Verify on tvOS 27 hardware/simulator with a Siri Remote: a left press moves exactly the configured amount backward, a right press moves exactly the same amount forward, repeated presses do not invoke both handlers, and drawer focus behavior remains usable.
- If public AVKit mechanisms cannot reliably intercept native left/right commands and route them through 10/15 seconds while retaining the native video surface, stop at the evidence: document the limitation and present the choice of accepting native behavior or separately approving a custom control surface. Do not silently replace the entire player UI.

## Tests and acceptance criteria

Preference tests must verify default 10, selection of 15, persistence across view recreation, and invalid-value fallback to 10. Coordinator tests must cover ±10 and ±15, zero/start clamping, duration/end clamping, non-finite/unready times, and a single seek per command.

UI/integration acceptance on tvOS 27 must verify Settings displays both values, a changed setting affects an already-open/new player consistently, left and right use the same interval in opposite directions, and native 2x/3x/4x speed-hold behavior remains unchanged. Verify the native `VideoPlayer`/AVPlayer decode surface remains in use, no duration-dependent long-hold behavior is present, and the silent-audio issue remains intentionally unchanged.

The existing deterministic build/test command should be run during implementation after this spec is approved. This document does not claim those checks pass at the current baseline.

## Risks

tvOS remote event delivery can differ between focusable SwiftUI controls and the AVKit player surface; duplicate move-command modifiers can cause double seeks or consume events unexpectedly. Seek completion may race with rapid presses, so coordinator commands must be serialized or safely superseded. Duration may be unavailable during startup, requiring a later clamp without disturbing playback. The principal product risk is that AVKit’s public event routing may not expose a reliable configurable skip hook while preserving native controls; that trade-off must remain explicit for user review.
