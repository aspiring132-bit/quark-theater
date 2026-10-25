import Foundation

struct MediaSyncResult: Equatable {
    let candidateCount: Int
    let addedCount: Int
    let changedCount: Int
    let autoMatchedCount: Int
    let needsConfirmationCount: Int
}

/// Keeps unresolved series files in the manual-confirmation surface instead
/// of repeatedly sending a filename with no episode number back to TMDB.
enum MediaLibrarySyncPolicy {
    static func shouldAutoRematch(candidate: ScannedMediaCandidate, isConfirmed: Bool) -> Bool {
        guard !isConfirmed else { return false }
        if candidate.parsedName.mediaType == .series {
            return candidate.parsedName.episodeNumber != nil
        }
        return true
    }

    static func needsManualConfirmation(candidate: ScannedMediaCandidate, isConfirmed: Bool) -> Bool {
        !isConfirmed && candidate.parsedName.mediaType == .series && candidate.parsedName.episodeNumber == nil
    }
}

/// Coordinates scanning, catalog reconciliation, and automatic TMDB matching
/// with single-flight concurrency protection.
@MainActor
final class MediaLibrarySyncService {
    private let client: QuarkClient
    private let accountID: String
    private let catalog: MediaCatalogRepository
    private let tokenStore: TMDBCredentialStore
    private let diagnostics: Diagnostics
    private let sourceRepository: SourceRepository

    init(client: QuarkClient, accountID: String, catalog: MediaCatalogRepository,
         tokenStore: TMDBCredentialStore, diagnostics: Diagnostics,
         sourceRepository: SourceRepository = .shared) {
        self.client = client
        self.accountID = accountID
        self.catalog = catalog
        self.tokenStore = tokenStore
        self.diagnostics = diagnostics
        self.sourceRepository = sourceRepository
    }

    func sync(
        boundFolderIDs: [String],
        boundFolderNames: [String: String] = [:],
        scraperLanguage: String = "zh-CN",
        progress: @escaping (String) -> Void
    ) async throws -> ([ScannedMediaCandidate], MediaSyncResult) {
        // Discover operational sources
        var allConfigured = sourceRepository.allSources().filter { s in
            s.isEnabled && s.type.isSupportedOnCurrentPlatform && s.status.isOperational
        }

        // If no sources configured or accountID is not in configured sources, ensure default Quark source
        if allConfigured.isEmpty || !allConfigured.contains(where: { $0.id == accountID }) {
            let defaultQuark = StorageSource(
                id: accountID,
                type: .quark,
                displayName: "夸克网盘",
                boundFolderIDs: boundFolderIDs,
                isEnabled: true
            )
            allConfigured.insert(defaultQuark, at: 0)
        }

        var allCandidates: [ScannedMediaCandidate] = []
        var totalAdded = 0
        var totalChanged = 0
        var totalAutoMatched = 0
        var totalNeedsConfirmation = 0

        let scanner = MediaLibraryScanner()

        for source in allConfigured {
            try Task.checkCancellation()

            var folderIDs = source.boundFolderIDs
            if folderIDs.isEmpty {
                let storedIDs = Array(BoundFolderStore.boundFolderIDs(accountID: source.id))
                folderIDs = storedIDs.isEmpty && source.id == accountID ? boundFolderIDs : storedIDs
            }
            if folderIDs.isEmpty && source.type == .quark {
                folderIDs = ["0"]
            }
            guard !folderIDs.isEmpty else { continue }

            var names = BoundFolderStore.boundFolderNames(accountID: source.id)
            if source.id == accountID {
                for (k, v) in boundFolderNames { names[k] = v }
            }

            let roots = folderIDs.map { MediaScanRoot(id: $0, name: names[$0]) }

            guard let adapter = sourceRepository.adapter(for: source.id, client: client), adapter.isAvailable else {
                continue
            }

            progress("正在读取 [\(source.displayName)] 绑定文件夹…")

            let sourceCandidates = try await scanner.scan(adapter: adapter, roots: roots) { count in
                progress("[\(source.displayName)] 已扫描 \(count) 个视频文件…")
            }

            try Task.checkCancellation()

            let changes = try catalog.reconcileScan(accountID: source.id, candidates: sourceCandidates)
            totalAdded += changes.added
            totalChanged += changes.changed

            let confirmedItems = try catalog.confirmed(accountID: source.id, includeAllSources: false)
            let confirmedByID = Dictionary(confirmedItems.map { ($0.fileId, $0) }, uniquingKeysWith: { first, _ in first })

            // Confirmed rows are stable input, including legacy rows missing a
            // season/episode. Only files absent from the catalog are eligible for
            // background matching, and unresolved series stay manual-confirmation.
            let unconfirmed = sourceCandidates.filter { candidate in
                MediaLibrarySyncPolicy.shouldAutoRematch(
                    candidate: candidate,
                    isConfirmed: confirmedByID[candidate.file.fileId] != nil
                )
            }
            let skippedUnresolvedSeriesCount = sourceCandidates.reduce(into: 0) { count, candidate in
                if MediaLibrarySyncPolicy.needsManualConfirmation(
                    candidate: candidate,
                    isConfirmed: confirmedByID[candidate.file.fileId] != nil
                ) {
                    count += 1
                }
            }
            totalNeedsConfirmation += skippedUnresolvedSeriesCount

            if !unconfirmed.isEmpty {
                let groups = Dictionary(grouping: unconfirmed, by: {
                    "\($0.parsedName.mediaType.rawValue):\($0.parsedName.title.lowercased())"
                })
                let totalGroups = groups.count
                var groupIndex = 0

                for (_, groupCandidates) in groups {
                    try Task.checkCancellation()
                    groupIndex += 1
                    guard let first = groupCandidates.first, !first.parsedName.title.isEmpty else { continue }

                    // Fast-path: If this series is already confirmed (e.g. another season exists), bind directly
                    let normalizedFirst = MediaAliasResolver.normalizeTitle(first.parsedName.title)
                    if first.parsedName.mediaType == .series,
                       let existingShow = confirmedItems.first(where: {
                           $0.mediaType == .series &&
                           (MediaAliasResolver.normalizeTitle($0.title) == normalizedFirst ||
                            $0.title.lowercased() == first.parsedName.title.lowercased())
                       }) {
                        for candidate in groupCandidates {
                            let item = MediaItem(
                                id: candidate.file.fileId,
                                fileId: candidate.file.fileId,
                                mediaType: candidate.parsedName.mediaType,
                                title: existingShow.title,
                                year: existingShow.year,
                                tmdbId: existingShow.tmdbId,
                                posterPath: existingShow.posterPath,
                                backdropPath: existingShow.backdropPath,
                                overview: existingShow.overview,
                                duration: nil,
                                matchConfidence: existingShow.matchConfidence ?? 0.95,
                                rating: existingShow.rating,
                                genreIDs: existingShow.genreIDs,
                                sourceType: source.type,
                                sourceId: source.id,
                                seasonNumber: candidate.parsedName.seasonNumber,
                                episodeNumber: candidate.parsedName.episodeNumber
                            )
                            try catalog.confirm(item, accountID: source.id)
                            totalAutoMatched += 1
                        }
                        continue
                    }

                    progress("正在自动刮削 TMDB：\(first.parsedName.title) (\(groupIndex)/\(totalGroups))…")

                    do {
                        let token = tokenStore.effectiveToken()
                        let learnedRecords = try catalog.learnedAliasRecords(
                            accountID: source.id,
                            mediaType: first.parsedName.mediaType,
                            sourceTitle: first.parsedName.title
                        )

                        var queryTitles = [first.parsedName.title]
                        if let canonical = learnedRecords.first?.canonicalTitle,
                           MediaAliasResolver.normalizeTitle(canonical) != MediaAliasResolver.normalizeTitle(first.parsedName.title) {
                            queryTitles.append(canonical)
                        }

                        var rawResults: [TMDBSearchResult] = []
                        var seenIDs = Set<String>()

                        for variant in queryTitles.prefix(2) {
                            try Task.checkCancellation()
                            let parsed = ParsedMediaName(
                                title: variant,
                                year: first.parsedName.year,
                                mediaType: first.parsedName.mediaType,
                                seasonNumber: first.parsedName.seasonNumber,
                                episodeNumber: first.parsedName.episodeNumber,
                                inferredFromParent: first.parsedName.inferredFromParent,
                                unresolvedReason: first.parsedName.unresolvedReason
                            )
                            let rows = try await TMDBService(diagnostics: diagnostics).search(
                                parsed,
                                apiReadToken: token,
                                language: scraperLanguage,
                                parentFolderName: first.parentFolderName,
                                ancestorFolderName: first.ancestorFolderName
                            )
                            for r in rows {
                                let key = "\(r.sourceMediaType?.rawValue ?? "unknown"):\(r.id)"
                                if seenIDs.insert(key).inserted { rawResults.append(r) }
                            }
                        }

                        let ranked = MediaMatchScorer.rank(
                            rawResults,
                            for: first.parsedName,
                            ancestorFolderName: first.ancestorFolderName,
                            learnedAliasRecords: learnedRecords
                        )

                        let disposition = MatchDecisionPolicy.evaluate(ranked, parsed: first.parsedName)
                        switch disposition {
                        case .autoConfirm(let best):
                            for candidate in groupCandidates {
                                let item = MediaItem(
                                    id: candidate.file.fileId,
                                    fileId: candidate.file.fileId,
                                    mediaType: candidate.parsedName.mediaType,
                                    title: best.result.displayTitle,
                                    year: best.result.year,
                                    tmdbId: best.result.id,
                                    posterPath: best.result.posterPath,
                                    backdropPath: best.result.backdropPath,
                                    overview: best.result.overview,
                                    duration: nil,
                                    matchConfidence: best.confidence,
                                    rating: best.result.voteAverage,
                                    genreIDs: best.result.genreIDs,
                                    sourceType: source.type,
                                    sourceId: source.id,
                                    seasonNumber: candidate.parsedName.seasonNumber,
                                    episodeNumber: candidate.parsedName.episodeNumber
                                )
                                try catalog.confirm(item, accountID: source.id)
                            }
                            totalAutoMatched += 1
                        case .needsUserConfirmation:
                            totalNeedsConfirmation += 1
                        case .unmatched:
                            break
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        diagnostics.record("自动刮削 \(first.parsedName.title) 失败：\(error.localizedDescription)")
                    }
                }
            }

            allCandidates.append(contentsOf: sourceCandidates)
        }

        let syncResult = MediaSyncResult(
            candidateCount: allCandidates.count,
            addedCount: totalAdded,
            changedCount: totalChanged,
            autoMatchedCount: totalAutoMatched,
            needsConfirmationCount: totalNeedsConfirmation
        )

        return (allCandidates, syncResult)
    }
}
