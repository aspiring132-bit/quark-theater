# Per-Episode Artwork Handoff Plan

> **For agentic workers:** Implement independently from player-focus UI work. Use test-first changes. Do not install or operate the physical Apple TV.

**Goal:** Display the correct episode still in each player drawer card with bounded requests and safe fallbacks.

**Architecture:** Fetch one season’s episode metadata per `(TMDB series ID, season number)` when the drawer needs it, then resolve card images by file ID and canonical episode number. Prefer confirmed catalog metadata; use filename parsing only when confirmed metadata is unavailable. Keep artwork resolution separate from playback identity and never infer an episode from list position.

**Tech Stack:** Swift, `URLSession`, existing SwiftUI image-loading patterns, XCTest, tvOS 27.

---

## Current Evidence and API Contract

- `QuarkTheater/Views/PlayerScreen.swift` currently passes one `backdropURL` to every drawer card.
- `QuarkTheater/Media/TMDBService.swift` owns TMDB requests and has an injectable `URLSession`, suitable for `URLProtocol` tests.
- TMDB’s official season-details response contains `episodes[]` with `episode_number` and optional `still_path`: [TV season details](https://developer.themoviedb.org/reference/tv-season-details).
- Do not make one HTTP request per episode. One season response must serve all cards for that season.

## Files and Responsibilities

- Modify `QuarkTheater/Media/TMDBService.swift` to decode season details and provide episode-number-to-still-path mapping.
- Add a focused provider/cache, preferably `QuarkTheater/Media/EpisodeArtworkProvider.swift`, keyed by TMDB series ID + season. Deduplicate in-flight requests; never persist credentials or signed URLs.
- Modify `QuarkTheater/Views/PlayerScreen.swift` and drawer cards to render per-file stills and fallbacks.
- Update `QuarkTheater/Views/MediaLibraryScreen.swift`, `MediaItemDetailScreen.swift`, and `FileBrowserScreen.swift` only as needed to pass already-available TMDB/season/episode context. Direct-browse playback without TMDB context must continue to work.
- Add decode/request tests to `QuarkTheaterTests/TMDBServiceTests.swift` and mapping/cache tests under `QuarkTheaterTests/`.

## Tasks and Acceptance

### Task 1: Season metadata service

- [ ] Add a response model for season episodes with `episode_number` and optional `still_path`.
- [ ] Add an injectable season-details request using current TMDB token/language handling. Diagnostics may record endpoint category/status but not token or full request URL.
- [ ] Add `URLProtocol` tests for request path, decoding, absent stills, and non-2xx responses.

### Task 2: Per-file image resolution

- [ ] Resolve metadata by file ID, preferring confirmed `MediaItem`; otherwise use the `ParsedMediaName` already passed to `PlayerScreen`.
- [ ] Request a still only when TMDB series ID, season, and episode are known. Do not infer an episode from ordering.
- [ ] Build the image URL from `still_path` using the existing TMDB image-host convention.
- [ ] Cache season mappings and share in-flight requests. Ignore/cancel stale responses after show/season changes.
- [ ] Fallback order: episode still → series backdrop → neutral placeholder. Missing artwork must not block playback or focus.

### Task 3: Tests and simulator evidence

- [ ] Verify episode 2 maps to episode 2’s still even if file order differs; unknown/missing still falls back; other show/season never reuses the mapping; repeated access makes no second season request.
- [ ] Build for tvOS 27 simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode_27_beta_6.app/Contents/Developer \
xcodebuild build-for-testing -project QuarkTheater.xcodeproj -scheme QuarkTheater \
  -destination 'id=3B8F12B8-476E-4171-9665-F645F63D4660' \
  CODE_SIGNING_ALLOWED=NO
```

- [ ] Once simulator test execution is healthy, run the unit tests and capture a screenshot showing distinct stills and the fallback state.
- [ ] If `DTServiceHubClient`/test-worker failure recurs, distinguish build success from unexecuted tests.

**Return package:** Test branch name and commit hash; changed-file list; exact test outputs; screenshots; known limits. Do not merge or push `main`; return results for review/alignment.

