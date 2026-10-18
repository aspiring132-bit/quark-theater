import Foundation

struct MediaSyncResult: Equatable {
    let candidateCount: Int
    let addedCount: Int
    let changedCount: Int
    let autoMatchedCount: Int
    let needsConfirmationCount: Int
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

    init(client: QuarkClient, accountID: String, catalog: MediaCatalogRepository,
         tokenStore: TMDBCredentialStore, diagnostics: Diagnostics) {
        self.client = client
        self.accountID = accountID
        self.catalog = catalog
        self.tokenStore = tokenStore
        self.diagnostics = diagnostics
    }

    func sync(
        boundFolderIDs: [String],
        boundFolderNames: [String: String] = [:],
        scraperLanguage: String = "zh-CN",
        progress: @escaping (String) -> Void
    ) async throws -> ([ScannedMediaCandidate], MediaSyncResult) {
        progress("正在读取绑定文件夹…")
        
        let roots = boundFolderIDs.map {
            MediaScanRoot(id: $0, name: boundFolderNames[$0])
        }

        let candidates = try await MediaLibraryScanner().scan(client: client, roots: roots) { count in
            progress("已扫描 \(count) 个视频文件…")
        }

        try Task.checkCancellation()

        let changes = try catalog.reconcileScan(accountID: accountID, candidates: candidates)
        let confirmedItems = try catalog.confirmed(accountID: accountID)
        let confirmedIDs = Set(confirmedItems.map(\.fileId))
        let unconfirmed = candidates.filter { !confirmedIDs.contains($0.file.fileId) }

        var autoMatchedCount = 0
        var needsConfirmationCount = 0

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
                            sourceType: .quark,
                            seasonNumber: candidate.parsedName.seasonNumber,
                            episodeNumber: candidate.parsedName.episodeNumber
                        )
                        try catalog.confirm(item, accountID: accountID)
                        autoMatchedCount += 1
                    }
                    continue
                }

                progress("正在自动刮削 TMDB：\(first.parsedName.title) (\(groupIndex)/\(totalGroups))…")

                do {
                    let token = tokenStore.effectiveToken()
                    let learnedRecords = try catalog.learnedAliasRecords(
                        accountID: accountID,
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
                                sourceType: .quark,
                                seasonNumber: candidate.parsedName.seasonNumber,
                                episodeNumber: candidate.parsedName.episodeNumber
                            )
                            try catalog.confirm(item, accountID: accountID)
                        }
                        autoMatchedCount += 1
                    case .needsUserConfirmation:
                        needsConfirmationCount += 1
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

        let syncResult = MediaSyncResult(
            candidateCount: candidates.count,
            addedCount: changes.added,
            changedCount: changes.changed,
            autoMatchedCount: autoMatchedCount,
            needsConfirmationCount: needsConfirmationCount
        )

        return (candidates, syncResult)
    }
}
