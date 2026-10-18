import Foundation
import SwiftUI

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    @Published private(set) var candidates: [ScannedMediaCandidate] = []
    @Published private(set) var confirmed: [MediaItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusProgress = ""
    @Published var message: String?

    private let syncService: MediaLibrarySyncService
    private let catalog: MediaCatalogRepository
    private let accountID: String
    private let diagnostics: Diagnostics
    private var syncTask: Task<Void, Never>?
    private var generation = 0

    init(client: QuarkClient, accountID: String, catalog: MediaCatalogRepository,
         tokenStore: TMDBCredentialStore, diagnostics: Diagnostics) {
        self.accountID = accountID
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.syncService = MediaLibrarySyncService(
            client: client,
            accountID: accountID,
            catalog: catalog,
            tokenStore: tokenStore,
            diagnostics: diagnostics
        )
        reloadConfirmed()
    }

    var confirmedIDs: Set<String> {
        Set(confirmed.map(\.fileId))
    }

    var fileByID: [String: CloudFile] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.file.fileId, $0.file) })
    }

    func posterItems(category: String, sortMode: String, searchText: String) -> [MediaItem] {
        let unique = Dictionary(grouping: confirmed, by: { "\($0.mediaType.rawValue):\($0.tmdbId ?? 0)" })
            .values.compactMap { $0.first }
        let filtered = unique.filter {
            (category == "all" || $0.mediaType.rawValue == category) &&
            (searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText))
        }
        return filtered.sorted {
            if sortMode == "year", $0.year != $1.year { return ($0.year ?? 0) > ($1.year ?? 0) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func unmatchedCandidates(category: String, searchText: String) -> [ScannedMediaCandidate] {
        candidates.filter {
            !confirmedIDs.contains($0.file.fileId) &&
            (category == "all" || $0.parsedName.mediaType.rawValue == category) &&
            (searchText.isEmpty || $0.parsedName.title.localizedCaseInsensitiveContains(searchText))
        }
    }

    func reloadConfirmed() {
        do {
            confirmed = try catalog.confirmed(accountID: accountID)
        } catch {
            message = error.localizedDescription
        }
    }

    func requestScan(scraperLanguage: String = "zh-CN", silent: Bool = false) {
        // Cancel existing task before starting a new scan
        syncTask?.cancel()
        generation += 1
        let currentGen = generation

        if !silent {
            isScanning = true
            message = nil
            statusProgress = "正在读取绑定文件夹…"
        }

        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !silent && self.generation == currentGen {
                    self.isScanning = false
                }
            }

            do {
                let boundIDs = Array(BoundFolderStore.boundFolderIDs(accountID: self.accountID))
                let boundNames = BoundFolderStore.boundFolderNames(accountID: self.accountID)

                let (scanned, result) = try await self.syncService.sync(
                    boundFolderIDs: boundIDs,
                    boundFolderNames: boundNames,
                    scraperLanguage: scraperLanguage
                ) { [weak self] progress in
                    guard let self, self.generation == currentGen, !silent else { return }
                    self.statusProgress = progress
                }

                guard !Task.isCancelled, self.generation == currentGen else { return }
                self.candidates = scanned
                self.reloadConfirmed()

                if !silent {
                    self.message = "扫描与刮削完成：新增 \(result.addedCount)，变更 \(result.changedCount)，已匹配海报 \(self.confirmed.count) 部影视。"
                    self.diagnostics.record("媒体扫描完成：\(result.candidateCount) 个视频；新增 \(result.addedCount)、变更 \(result.changedCount)、已匹配 \(self.confirmed.count)")
                }
            } catch is CancellationError {
                guard self.generation == currentGen, !silent else { return }
                self.message = "扫描已取消。"
            } catch {
                guard self.generation == currentGen, !silent else { return }
                self.message = error.localizedDescription
                self.diagnostics.recordError(error, context: "媒体扫描")
            }
        }
    }

    func cancelScan() {
        syncTask?.cancel()
        isScanning = false
        message = "扫描已取消。"
    }
}
