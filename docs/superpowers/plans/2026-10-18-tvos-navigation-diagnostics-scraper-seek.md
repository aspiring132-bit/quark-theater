# tvOS Navigation, Diagnostics, Scraper, and Seek Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix Siri Remote focus behavior, add durable redacted diagnostics for Quark requests and playback/audio, implement the approved media-identification design, and add configurable 10/15-second seeks for tvOS 27.

**Architecture:** Implement navigation and diagnostics first, using typed focus reducers and a structured JSONL diagnostics recorder. Then implement the already approved scraper and seek designs, preserving AVPlayer/AVKit playback and using the diagnostics API at network and playback boundaries. Keep all external identifiers and secrets out of persisted/exported logs.

**Tech Stack:** Swift 6, SwiftUI, AVKit/AVFoundation, Foundation JSON/Codable, SQLite-backed media repositories, XCTest, Xcode 27.0 / tvOS 27.0 Simulator.

---

## File map

- `QuarkTheater/Core/Diagnostics.swift`: observable diagnostics facade, typed categories/events, sanitization, bounded in-memory view.
- `QuarkTheater/Core/DiagnosticsStore.swift` (new): serialized JSONL persistence, retention/rotation, sanitized export.
- `QuarkTheater/Core/FocusNavigation.swift` (new): pure focus/command reducer and target identifiers.
- `QuarkTheater/Core/QuarkClient.swift`, `QuarkTheater/Services/LiveQuarkClient.swift`: safe request and fallback observability.
- `QuarkTheater/Playback/PlaybackCoordinator.swift`, `QuarkTheater/Playback/PlaybackProbe.swift`: player/audio snapshots, silence marker, media/error/access notifications, observer lifecycle.
- `QuarkTheater/Views/RootView.swift`, `MediaLibraryScreen.swift`, `PlayerScreen.swift`, `FolderSelectionScreen.swift`, `MediaItemDetailScreen.swift`, `FileBrowserScreen.swift`, `TMDBMatchScreen.swift`, `HistoryScreen.swift`, `LoginScreen.swift`: focus ownership and diagnostics UI.
- `QuarkTheater/Media/*.swift`, `QuarkTheater/Repositories/MediaCatalogRepository.swift`, `QuarkTheater/Services/BoundFolderStore.swift`: approved staged recognition, matching disposition, and learned aliases.
- `QuarkTheaterTests/`: new focus/diagnostics/seek/alias tests plus repairs to stale fixtures.

## Task 1: Establish passing test compilation baseline

**Files:** `QuarkTheaterTests/MediaCatalogRepositoryTests.swift`, `QuarkTheaterTests/MediaMatchScorerTests.swift`.

- [ ] Update old test constructor calls only, supplying the currently required parent-folder/ancestor-folder and `inferredFromParent` values. Do not change production types or expected behavior in this fixture-only task.
- [ ] Run the exact tvOS 27 simulator test command below; confirm that any remaining failures are behavioral test failures, not test-target compile errors.

Run:

```sh
DEVELOPER_DIR=/Applications/Xcode_27_beta_6.app/Contents/Developer xcodebuild test -project QuarkTheater.xcodeproj -scheme QuarkTheater -destination 'platform=tvOS Simulator,id=5B1B0B09-3109-474C-B324-DB5493575523' -derivedDataPath /tmp/quark-theater-derived-data
```

## Task 2: Structured diagnostics store and redaction

**Files:** `Diagnostics.swift`, new `DiagnosticsStore.swift`, new `DiagnosticsStoreTests.swift`, project file if explicit file references are required.

- [ ] Write failing tests for JSONL append/read ordering, 14-day/10-MB rotation, malformed final-line recovery, export, and sensitive-field/value redaction.
- [ ] Run focused diagnostics tests and verify expected redaction/behavior failures.
- [ ] Implement one serialized writer, typed event/category/severity identifiers, allow-listed metadata, in-memory newest-first projection, local rolling storage, and export file generation.
- [ ] Run diagnostics tests, then run all tests to ensure the old string-based `record` compatibility bridge remains safe or has been fully migrated.

## Task 3: Instrument cloud/TMDB/scraper request boundaries

**Files:** `Core/QuarkClient.swift`, `Services/LiveQuarkClient.swift`, `Media/TMDBService.swift`, approved media pipeline files, and diagnostics tests.

- [ ] Write failing tests asserting successful requests, failures, `/file/v2/play` fallback, TMDB endpoint types, and match-decision stages emit correlated diagnostic events without raw URLs, query values, bodies, or titles.
- [ ] Implement request timing/status/fallback events and safe media-stage events; classify errors by stable type/code rather than `localizedDescription`.
- [ ] Run the focused request/scraper diagnostic tests and the full test suite.

## Task 4: Player audio diagnostics and no-sound marker

**Files:** `Playback/PlaybackCoordinator.swift`, `Playback/PlaybackProbe.swift`, `Views/PlayerScreen.swift`, `PlaybackCoordinatorTests.swift`.

- [ ] Write failing tests for player transition event mapping, audio selection changes, sanitized AVPlayer log summaries, and a user-triggered silent-audio snapshot.
- [ ] Implement observations for item/player status, waiting reason, buffer health, selected track/track metadata, audio selection, access/error-log notifications, and safe route metadata when available.
- [ ] Add a player “标记无声” action that records an immediate snapshot without installing an audio tap or changing playback behavior.
- [ ] Ensure all observers are removed by both `stop()` and item replacement; test observer lifecycle through coordinator seams.
- [ ] Run focused playback tests and full suite.

## Task 5: Settings diagnostics view and retrieval

**Files:** `Views/RootView.swift`, any new diagnostics view under `Views/`, diagnostics tests.

- [ ] Add category filtering and correct newest-first display to the existing diagnostics settings section.
- [ ] Add clear and export controls; export a sanitized file to the app Documents directory and show its safe filename/path for Xcode app-container retrieval.
- [ ] Add a UI model test or pure projection test for newest 200–500 events, category filter, empty state, and export confirmation.
- [ ] Run full tests and a tvOS 27 build.

## Task 6: Repair focus ownership across screens

**Files:** new `Core/FocusNavigation.swift`, `Views/RootView.swift`, `MediaLibraryScreen.swift`, `PlayerScreen.swift`, and all other focus-bearing views listed in the file map; new focus reducer tests.

- [ ] Write reducer tests for root tab entry/Back, drawer open/tab/content/close, horizontal seek-vs-focus routing, and invalid focus-target fallback.
- [ ] Run tests to verify the reducer cases fail against the unimplemented API.
- [ ] Replace shared Boolean/zone targets with unique typed targets for independently actionable controls; wire reusable filter controls to parent-owned focus bindings.
- [ ] Keep exactly one `.onMoveCommand` in `PlayerScreen`; route directions based on drawer state and focused target.
- [ ] Make root Back behavior layered and non-consuming when no app action applies; restore valid focus after closing modals/details/player and after hidden controls become visible.
- [ ] Remove the dock's off-screen/transparent focus destination behavior and restore a visible on-screen dock focus target.
- [ ] Add structured focus transition events with rate-limited safe metadata.
- [ ] Run focused focus tests, full tests, and manual tvOS 27 simulator remote checks for root tabs, media rows, player drawer, settings, detail, modal, and Back behavior.

## Task 7: Implement approved staged media recognition and conservative matching

**Files:** `Media/FilenameParser.swift`, new `Media/MediaAliasResolver.swift`, `Media/MediaLibraryScanner.swift`, `Media/TMDBService.swift`, `Media/MediaMatchScorer.swift`, `Services/BoundFolderStore.swift`, `Repositories/MediaCatalogRepository.swift`, `Media/Models.swift`, `Views/MediaLibraryScreen.swift`, `Views/TMDBMatchScreen.swift`, focused tests.

- [ ] Add failing tests for named-root context, S01/S02 with bare episode numbers, generic folder exclusion, homophone aliases, typo-safe exact aliases, query aggregation, cross-type rejection, ambiguity margins, `0.58` non-persistence, manual episode preservation, alias account/type isolation, removal, and legacy decoding.
- [ ] Verify the new tests fail for the intended missing behavior.
- [ ] Implement staged filename/path/root recognition, stable alias candidate generation, search aggregation with provenance, centralized `.autoConfirm` / `.needsConfirmation` / `.unmatched` disposition, and explicit/manual-only alias learning.
- [ ] Preserve old catalog and bound-folder decoding. Do not copy MoviePilot source or broaden scope to its regex DSL/provider/anime features.
- [ ] Run focused parser/scanner/matcher/repository tests and full suite.

## Task 8: Implement configurable 10/15-second playback seeking

**Files:** `Views/RootView.swift`, `Views/PlayerScreen.swift`, `Playback/PlaybackCoordinator.swift`, new seek-preference tests and coordinator tests.

- [ ] Add failing tests for default 10 seconds, choosing/persisting 15 seconds, invalid stored values falling back to 10, seek direction, start/end clamping, non-finite times, and one seek per remote event.
- [ ] Implement a persisted preference and Settings segmented picker; route one left/right action path to coordinator seek methods.
- [ ] Keep native `VideoPlayer`, native 2x/3x/4x speed hold behavior, and normal left/right focus movement while the drawer is open.
- [ ] Run focused seek tests and full suite.

## Task 9: Final Xcode 27 verification and review

- [ ] Run `git diff --check`, inspect `git status` and full diff for scope, secrets, and unredacted log paths/values.
- [ ] Run the full tvOS 27 simulator tests with the exact command from Task 1.
- [ ] Run a Release or Debug simulator build and record the `.app` output path.
- [ ] Open/run in Apple TV 4K (3rd generation) tvOS 27 simulator and manually verify remote navigation, left/right 10/15-second seek, diagnostics marker, settings log retrieval, and scraper UI behavior.
- [ ] Report any hardware-only checks not possible in Simulator (physical Siri Remote, actual Quark stream, real silent-audio repro) separately; do not claim they were verified.
