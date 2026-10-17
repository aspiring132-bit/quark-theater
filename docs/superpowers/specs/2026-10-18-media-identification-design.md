# Media identification and matching design

## Goals

- Turn a cloud video path into a deterministic recognition record containing title, media type, year (when present), and season/episode metadata.
- Use filename, the complete parent path, and the named bound root as separate evidence sources so a directory-only series layout remains recognizable.
- Match movies and series through compatible TMDB endpoints, aggregate all raw, canonical, built-in-alias, and learned-alias results, and make confidence/state explicit.
- Keep built-in homophone aliases useful while preventing substring corruption; learn account- and media-type-scoped aliases only after an explicit manual confirmation.
- Preserve enough provenance and context to explain a result, undo a wrong learned alias, and retry an unresolved candidate without rescanning.

This is a clean Swift rewrite inspired by the useful MoviePilot concepts of staged file/parent/root parsing, applying user rules before parsing, and separating pure recognition from persistence. It does not copy MoviePilot source or its GPL-3.0 implementation. The MoviePilot regex DSL, anime/provider adapters, offsets, and unrelated features are out of scope; the application repository has no declared license.

## Non-goals

- No provider abstraction beyond the current TMDB integration, no anime-specific parsing, no regex DSL, no episode offsets, and no generalized rule language in this milestone.
- No automatic alias learning, including learning from an auto-confirmed result.
- No treating an uncontextualized numeric filename as a movie.
- No redesign of the catalog UI or database engine beyond the persistence needed for match state and aliases.

## Current-code constraints and affected modules

The design extends the responsibilities of `FilenameParser`, `MediaLibraryScanner`, `TMDBService`, and `MediaMatchScorer`; the scan/match orchestration currently lives in `MediaLibraryScreen`. `BoundFolderStore` already stores bound folder IDs and names, but `MediaLibraryScreen` currently passes only IDs to the scanner, so root context is lost. `MediaCatalogRepository` remains the persistence boundary for confirmed media and scan reconciliation. `TMDBMatchScreen` remains the manual confirmation surface, but its save path must carry the parsed season/episode values. `Models.swift` owns the serializable media and candidate state.

The current audit also establishes these required corrections: `MediaLibraryScreen` persists an automatic match at confidence `>= 0.58` although the scorer's stated auto-confirm threshold is `0.95`; `MediaMatchScorer` does not compare the original and canonical alias provenance; and `TMDBService.search` returns the first non-empty query response, losing candidates from later variants and cross-type provenance.

## Architecture and data flow

Recognition is a pure staged pipeline. Persistence and network calls consume its value objects but do not mutate parsing state.

1. **Scan context.** The scanner receives a bound root as `(id, name)` (or an explicit unnamed-root marker), carries the root name plus every descendant component in a path context, and records the complete path on each video candidate. Existing ID-only callers remain readable through a compatibility adapter that supplies no root name.
2. **Stage A — filename.** Strip the extension, normalize separators/Unicode case and whitespace, extract an explicit title/year, and recognize explicit `SxxExx`/equivalent episode notation. Do not infer a movie from a bare number.
3. **Stage B — path.** Inspect components from the immediate parent outward. A strict season folder is exactly a season marker such as `S01`, `S02`, `Season 1`, or the existing Chinese season form, with boundary checks so a title containing `S01` is not itself accepted as a season folder. A bare `1` or `01` filename is an episode only when a valid series title and, when applicable, season context come from a parent/path/root stage. Generic intermediates such as `Extras`, `Specials`, `Featurettes`, `Trailers`, and ordinary numeric transport folders do not become titles.
4. **Stage C — named root.** Use the bound root name as the outermost series-title evidence after stripping share prefixes, season markers, release tags, and generic folder labels. Root evidence participates only when it is named; an ID without a name cannot supply a title.
5. **Recognition result.** Emit a `ParsedMediaName`-compatible value plus evidence/provenance: source path, title candidates by stage, canonical alias candidates, media type, year, season/episode, and an `unresolvedReason` when no title context exists. Recognition may return `unresolved` rather than fabricating a title.
6. **Query planning.** Apply user rules before matching (the first milestone has only the persisted learned-alias rule). Normalize each input using one shared exact-title normalizer. Generate raw, canonical built-in-alias, and applicable learned-alias queries with stable deduplication. Built-in replacements are whole-title/token-aware exact rules: `蜘蛛侠` must never become `蜘蛛侠侠`; a rule must not rewrite a substring inside an already canonical title.
7. **Search aggregation.** Execute all planned query/type/language combinations needed for the candidate. Collect every response, retaining query variant, alias source, requested endpoint type, and returned type provenance. Never stop at the first non-empty response. Deduplicate by `(TMDB id, compatible media type)` while retaining the strongest provenance.
8. **Scoring and disposition.** Score only results compatible with the parsed media type (`movie` with movie, `series` with TV). Compare normalized parsed title against both TMDB display and original titles and include year, path evidence, alias provenance, and season/episode consistency where applicable. Rank deterministically. Auto-confirm only when the top result is strong and unambiguous (the existing `0.95` threshold is the minimum, plus a meaningful margin over the runner-up and no incompatible-type ambiguity). Lower-confidence or tied results enter `pendingConfirmation`; no-result, unresolved, and failed-query cases enter `unmatched` with a reason.
9. **Persistence.** Only an explicit user confirmation may create a confirmed `MediaItem`. A confirmation stores the selected TMDB identity, confidence, media type, source file, and season/episode metadata. It may also create/update a learned alias for the exact normalized input, scoped by account ID and media type, with source `manualConfirmation` and a reversible relationship to the selected identity. Auto-confirm never creates a learned alias.

## Persistence and migration compatibility

Keep existing `MediaItem` decoding compatible: absent new fields decode to current defaults, and existing confirmed rows remain playable and editable. Add versioned storage for match disposition/provenance and learned aliases rather than changing the meaning of existing `matchConfidence`. A learned alias record contains account ID, media type, normalized source title, canonical title/TMDB identity, creation/update timestamps, and origin; enforce uniqueness on account/media type/source title. Removing an alias deletes or deactivates only that learned record and must not delete confirmed media. Existing `BoundFolderStore` ID/name keys remain readable; the scanner receives a name when available and falls back safely when old data has only an ID.

Migration must never promote existing low-confidence confirmed rows into auto-confirmed rows. Existing catalog rows remain confirmed as-is; new disposition is derived as `confirmed` for those rows unless the user explicitly rematches them. The current stale test fixtures using old `ParsedMediaName`/`TMDBSearchResult` constructors are an implementation-time compatibility repair, not a design dependency.

## Error and ambiguity handling

- Missing root name, generic-only path, or bare numeric filename: keep the file visible as `unmatched` with `missingSeriesContext`; never query it as a movie.
- Conflicting season/title evidence: retain all evidence, prefer the strict season folder, and require confirmation when the conflict changes the candidate type or identity.
- TMDB timeout, authentication, rate limit, or partial variant failure: preserve successful candidates and surface a retryable error; do not convert a network failure into “no match.”
- Cross-type or tied top results: discard incompatible types from scoring and send ties to confirmation.
- Wrong learned alias: provide removal from settings or the manual-match flow, immediately stop using it for future queries, and leave prior confirmed catalog records unchanged unless the user rematches them.

## Tests and acceptance criteria

Pure parser/scanner tests must cover at least:

- `/影视/权力的游戏/S01/01.mp4` with a named root or title-bearing ancestor → series, title `权力的游戏`, season 1, episode 1.
- `/影视/Extras/01.mp4` with no named series root → unresolved, not movie `01` and not title `Extras`.
- A bound root with ID plus name `大西洋帝国`, descendant `S02`, and file `03.mkv` → title from the named root, season 2, episode 3.
- An ID-only bound root and bare `09.mp4` → unresolved with `missingSeriesContext`.
- `蜘蛛侠.mp4` remains exactly `蜘蛛侠` after built-in alias normalization; `蛛丝.mp4` may produce canonical `蜘蛛侠`; no substring rewrite yields `蜘蛛侠侠`.
- `S01` embedded in a title folder is not treated as a season folder unless the component is a strict season marker; `Extras`/`Specials` never become titles.

Matching tests must verify all aliases are queried/aggregated, later non-empty results are not dropped, TMDB movie results cannot win a series candidate, original and canonical titles affect scoring, top-result ambiguity remains pending, and auto-confirm requires the strong score plus separation rule. Manual confirmation must persist season/episode on every selected file. Alias tests must verify account/media-type isolation, no auto-learn, and removal.

Migration tests must decode old catalog records and old bound-folder records unchanged. Existing deterministic test commands and the approved fixture repairs are implementation work after this spec is reviewed; this document does not claim those tests pass today.

## Risks

The largest false-positive risk is overly broad path-title extraction; strict folder markers and generic-folder exclusions intentionally favor unmatched over a wrong catalog entry. Query aggregation increases TMDB requests, so bounded variant counts, stable deduplication, caching, and cancellation are required. Learned aliases can amplify a human mistake, so they are scoped, explicit, visible, and removable. Legacy rows lack provenance, so migration must preserve behavior without pretending their original confidence path is known.
