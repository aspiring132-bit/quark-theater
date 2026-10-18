# tvOS Focus and Diagnostics Design

## Goals

- Make Siri Remote navigation deterministic across root tabs, media-library controls, player drawer controls, detail pages, and settings.
- Ensure each screen has one clear owner for directional commands and a stable focus target when controls are inserted, removed, hidden, or restored.
- Replace ephemeral free-form diagnostics with structured, persistent, exportable, privacy-safe events spanning UI focus, Quark/cloud requests, media matching, and playback/audio.
- Capture useful AVPlayer state around user-reported silence without claiming the app can detect whether sound is physically audible.

## Non-goals

- Do not replace native AVKit video/audio playback or install an audio PCM tap.
- Do not upload diagnostics automatically or include raw request/response bodies.
- Do not log credentials, cookies, tokens, full URLs/query strings, or arbitrary error descriptions.
- Do not redesign every screen's visuals; only adjust focus behavior and feedback where required.

## Findings informing the design

- `PlayerScreen` installs two `.onMoveCommand` handlers; horizontal presses can have competing seek and focus-navigation owners.
- `MediaLibraryScreen` binds multiple hero controls to one Boolean focus state and has a filter focus state disconnected from the filter-pill components.
- Player tab controls and content buttons bind many different controls to the same enum values (`.tabBar` / `.content`), so programmatic focus is ambiguous.
- `RootView` handles Back globally even when no action is appropriate, and its off-screen/transparent dock cannot reliably restore focus after navigation.
- Existing `Diagnostics` is an in-memory list of 100 strings. It lacks persistence, category, severity, correlation IDs, export, and enforced redaction. Its view currently renders the oldest retained slice.
- Current player observations cover overall status/buffering but not selected audio-track changes, media format, AVPlayer access/error logs, or the audio-output route. An empty alternate-audio list does not prove audio is rendering.

## Architecture

### Focus ownership

Each screen uses a typed focus target with a unique identity for each independently actionable control. Reusable components either receive a target binding from their parent or own a focus state that the parent explicitly observes; they must not create disconnected state for transitions the parent relies on. Screen entry chooses a default target and screen exit restores the previous valid target where appropriate.

`PlayerScreen` has one directional-command reducer. Up/down open and traverse/close the drawer; left/right seek only when the drawer is closed and remain normal focus navigation while the drawer is open. Closing a drawer returns focus to its trigger. Back is layered: close transient player UI first, dismiss the current detail/player/modal next, return a non-media root tab to the media tab, and otherwise preserve the system behavior.

The dock remains a valid on-screen focus destination. `focusSection()` may guide directional movement but is not treated as explicit focus restoration. Pure transition logic is extracted and unit-tested; tvOS 27 simulator and Siri Remote checks verify real focus geometry and command routing.

### Structured diagnostics

`Diagnostics` remains the application-facing observable facade, backed by one serialized recorder and a rotating JSONL file in Application Support. Each record has timestamp, session ID, category, level, event code, optional correlation ID, and allow-listed scalar metadata. Categories include `navigation`, `cloud`, `scraping`, `playback`, and `audio`.

The store keeps the newest events in UI memory, persists them across launches, and rotates by age (14 days) and size (10 MB maximum). The Settings diagnostics section shows the newest records, supports filtering by category, clearing, and creating a sanitized export file in Documents for retrieval through Xcode's app-container tools. Safe summaries may also be mirrored to OSLog.

Privacy is enforced centrally before persistence and export. Callers use typed event cases and allow-listed fields; raw URL, query, headers, cookies, tokens, request/response body, account ID, file ID, full file path/name, and arbitrary localized error text are excluded. Network events use endpoint identifiers, status/error codes, latency, retry/fallback outcomes, and host-only data where needed.

### Playback and silence evidence

The coordinator records item/player state transitions, playback format/source, time-control status and waiting reason, buffer flags, time position, selected audio option and track metadata, audio-selection changes, AVPlayer access/error-log summaries, playback stalls/failures/retries, and audio output-route changes when available.

The player offers a “标记无声” action. It captures an immediate sanitized snapshot (playback time/state, selected track, track count/metadata, buffer state, route, and latest AVPlayer access/error events) to correlate with surrounding playback logs. This is a user report marker, not automatic acoustic silence detection. Pause/resume recovery and full reload remain distinct event sequences.

### Cloud and scraping observability

The Quark transport records operation/endpoint identifiers, HTTP/business status, elapsed time, retry count, and fallback path without logging request secrets or bodies. The recognition pipeline records safe stage events: input source class, candidate count, alias provenance class, disposition, confidence bucket, TMDB endpoint type, and error category; it excludes raw titles and paths from persisted diagnostics.

## Error handling

Diagnostics must never break playback or navigation. Failed writes are mirrored as a sanitized OSLog warning, and the in-memory ring remains available. Serialization/rotation is single-writer and recoverable from a truncated final JSONL line. Export failure is surfaced as a nonfatal UI message.

## Tests and acceptance

- Focus reducer tests prove each directional event has one transition and drawer state determines whether horizontal movement seeks or changes focused controls.
- Screen-level focus tests use unique focus identifiers and validate entry, close/restore, and Back layering; tvOS 27 simulator and hardware checks verify actual remote routing.
- Diagnostics tests cover JSON encoding/decoding, newest-first reads, rotation/retention, export, malformed trailing records, redaction of URL/query/headers/tokens/file IDs, and safe error classification.
- Playback tests cover state-event summaries, selected audio track changes, access/error-log sanitization, and silence-marker snapshots.
- Cloud/media tests verify endpoint/fallback and scraper stages emit correlated, redacted events.
- The app must compile and tests must run on the tvOS 27 simulator using Xcode 27.0. A successful simulator build is not reported as real-device confirmation.

## Assumptions

- “云盘调试日志” means local Quark/cloud API request and fallback diagnostics.
- Logs stay on-device/local; the user retrieves the sanitized export with Xcode when needed. No remote support upload is part of this feature.
- The diagnostics subsystem may retain filenames/titles only in volatile player presentation state needed for the current UI; durable support logs use content-independent identifiers/categories only.
