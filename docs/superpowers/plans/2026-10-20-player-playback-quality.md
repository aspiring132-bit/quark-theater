# Player Playback Quality Implementation Plan

**Goal:** Improve drawer focus readability/spacing, hint lifecycle and seek feedback while adding diagnostics for intermittent audio loss without changing playback behavior.

**Architecture:** Keep KSPlayer as the playback engine. Add small pure policy helpers for testable timer/seek behavior, extend the existing allow-listed diagnostics schema for AVAudioSession lifecycle snapshots, and expose a manual silent marker from the audio drawer. UI changes stay localized to `PlayerScreen`.

**Verification:** Run targeted XCTest cases, build/install/launch the tvOS app on simulator `3B8F12B8-476E-4171-9665-F645F63D4660` with Xcode 27 beta, then install and verify on the explicitly requested physical Apple TV named `主卧`.

**Audio limitation:** AVAudioSession exposes category, mode, route, output volume and channel count, but no reliable public getter for the session's active state. The diagnostics therefore do not invent an `audioSessionActive` field; audible output at the TV endpoint also cannot be proven programmatically.

## Tasks

1. Add failing tests for hint reset policy, seek HUD lifecycle, and audio diagnostic metadata; run them to confirm the missing behavior.
2. Implement the policies and diagnostics observers/snapshots in `PlaybackCoordinator` and `DiagnosticsStore`.
3. Update `PlayerScreen` drawer focus styling, spacing, hint icon/timer, silent marker, and seek HUD.
   - Keep a dedicated episode-list viewport tall enough for the focused 1.05× card and its top badges.
   - Handle Back at the drawer focus scope and keep the player presented.
4. Defer tvOS app-icon layer replacement: the only available square asset is explicitly labeled a concept draft in `docs/branding/mujio/README.md`, so no production icon is copied or invented until final layered artwork is supplied.
5. Run targeted tests and simulator build/install/launch; record exact outcomes.
