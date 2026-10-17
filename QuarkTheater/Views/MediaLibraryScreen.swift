import SwiftUI

private enum MediaLibrarySheet: Identifiable {
    case match(ScannedMediaCandidate)
    case detail(MediaItem)
    var id: String {
        switch self {
        case .match(let candidate): return "match:\(candidate.id)"
        case .detail(let item): return "detail:\(item.id)"
        }
    }
}

@MainActor
struct MediaLibraryScreen: View {
    let client: QuarkClient
    let accountID: String
    let history: HistoryRepository
    let tokenStore: TMDBCredentialStore
    let catalog: MediaCatalogRepository
    let diagnostics: Diagnostics

    @State private var candidates: [ScannedMediaCandidate] = []
    @State private var confirmed: [MediaItem] = []
    @State private var activeSheet: MediaLibrarySheet?
    @State private var showFolderSelection = false
    @State private var category = "all"
    @State private var sortMode = "name"
    @State private var searchText = ""
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var statusProgress = ""
    @State private var message: String?
    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"

    private var confirmedIDs: Set<String> { Set(confirmed.map(\.fileId)) }

    private var posterItems: [MediaItem] {
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

    private var unmatchedCandidates: [ScannedMediaCandidate] {
        candidates.filter {
            !confirmedIDs.contains($0.file.fileId) &&
            (category == "all" || $0.parsedName.mediaType.rawValue == category) &&
            (searchText.isEmpty || $0.parsedName.title.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Title Area
                VStack(alignment: .leading, spacing: 8) {
                    Text("媒体库").font(.system(size: 48, weight: .bold, design: .rounded))
                    let boundCount = BoundFolderStore.boundFolderIDs(accountID: accountID).count
                    Text("绑定影视文件夹：\(boundCount > 0 ? "\(boundCount) 个" : "全盘") · 扫描候选：\(candidates.count) · 已匹配海报：\(confirmed.count)")
                        .foregroundStyle(.secondary)
                }

                // MARK: - 第一焦点操作行 (Descending from Tab Bar lands here first!)
                HStack(spacing: 20) {
                    Button {
                        if isScanning {
                            scanTask?.cancel()
                        } else {
                            scanTask = Task { await scan() }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isScanning ? "xmark.circle" : "arrow.triangle.2.circlepath")
                            Text(isScanning ? "取消扫描与匹配" : "重新匹配与刮削")
                        }
                        .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)

                    Button {
                        showFolderSelection = true
                    } label: {
                        let count = BoundFolderStore.boundFolderIDs(accountID: accountID).count
                        Label(count > 0 ? "管理绑定文件夹 (\(count) 个)" : "管理绑定文件夹", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)

                    if !unmatchedCandidates.isEmpty {
                        Button {
                            Task { await autoMatchUnmatched() }
                        } label: {
                            Label("批量自动匹配未识别 (\(unmatchedCandidates.count) 项)", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isScanning)
                    }
                }

                // Progress & Notification
                if isScanning {
                    HStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text(statusProgress.isEmpty ? "正在扫描网盘文件…" : statusProgress)
                            .font(.callout)
                            .foregroundStyle(.cyan)
                    }
                    .padding(.vertical, 8)
                }

                if let message {
                    Text(message)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if candidates.isEmpty && !isScanning {
                    Text("点击上方“重新匹配与刮削”开始扫描绑定文件夹并自动下载海报封面。")
                        .foregroundStyle(.secondary)
                }

                // Filter & Search Controls
                HStack(spacing: 20) {
                    TextField("搜索媒体库片名", text: $searchText).frame(maxWidth: 500)
                    Picker("分类", selection: $category) {
                        Text("全部").tag("all")
                        Text("电影").tag(MediaType.movie.rawValue)
                        Text("电视剧").tag(MediaType.series.rawValue)
                    }.pickerStyle(.segmented).frame(maxWidth: 520)
                    Picker("排序", selection: $sortMode) {
                        Text("名称").tag("name")
                        Text("年份").tag("year")
                    }.pickerStyle(.segmented).frame(maxWidth: 420)
                }

                // Matched Posters Grid
                if !posterItems.isEmpty {
                    Text("已匹配影视 (\(posterItems.count))").font(.title2.bold())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 5), spacing: 28) {
                        ForEach(posterItems) { item in
                            Button { activeSheet = .detail(item) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    poster(item.posterPath)
                                    Text(item.title).font(.headline).lineLimit(2)
                                    Text(item.year.map(String.init) ?? "年份未知")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                // Unmatched List
                if !unmatchedCandidates.isEmpty {
                    Text("待匹配 (\(unmatchedCandidates.count))").font(.title2.bold())
                    ForEach(unmatchedCandidates) { candidate in
                        Button { activeSheet = .match(candidate) } label: {
                            HStack(spacing: 24) {
                                Image(systemName: candidate.parsedName.mediaType == .series ? "tv" : "film")
                                    .font(.system(size: 34)).frame(width: 48)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(candidate.parsedName.title).font(.headline)
                                    let detail = candidate.parsedName.mediaType == .series
                                        ? "第 \(candidate.parsedName.seasonNumber ?? 0) 季 · 第 \(candidate.parsedName.episodeNumber ?? 0) 集"
                                        : (candidate.parsedName.year.map(String.init) ?? "年份未知")
                                    Text("\(detail) · \(candidate.file.name)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("手动匹配 TMDB").foregroundStyle(.cyan)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                    }
                }
            }
            .frame(maxWidth: 1500, alignment: .leading)
            .padding(60)
        }
        .task { reloadConfirmed() }
        .onDisappear { scanTask?.cancel() }
        .sheet(item: $activeSheet) { route in
            switch route {
            case .match(let candidate):
                TMDBMatchScreen(
                    candidate: candidate,
                    accountID: accountID,
                    tokenStore: tokenStore,
                    catalog: catalog,
                    diagnostics: diagnostics
                ) {
                    reloadConfirmed()
                }
            case .detail(let item):
                let related = confirmed.filter { $0.tmdbId == item.tmdbId && $0.mediaType == item.mediaType }
                MediaItemDetailScreen(
                    item: item,
                    related: related,
                    candidates: candidates,
                    client: client,
                    accountID: accountID,
                    history: history,
                    tokenStore: tokenStore,
                    catalog: catalog,
                    diagnostics: diagnostics
                ) {
                    reloadConfirmed()
                }
            }
        }
        .sheet(isPresented: $showFolderSelection) {
            FolderSelectionScreen(client: client, accountID: accountID, diagnostics: diagnostics, isPresented: $showFolderSelection) {
                Task { await scan() }
            }
        }
    }

    // MARK: - Scanning & Automatic TMDB Scraping
    private func scan() async {
        isScanning = true
        statusProgress = "正在读取绑定文件夹…"
        message = nil
        defer { isScanning = false }

        do {
            let boundIDs = Array(BoundFolderStore.boundFolderIDs(accountID: accountID))
            candidates = try await MediaLibraryScanner().scan(client: client, folderIDs: boundIDs) { count in
                statusProgress = "已扫描 \(count) 个文件…"
            }

            let changes = try catalog.reconcileScan(accountID: accountID, candidates: candidates)
            reloadConfirmed()

            // Run automatic TMDB scraper pass for unconfirmed items
            await autoMatchUnmatched()

            reloadConfirmed()
            message = "扫描与刮削完成：新增 \(changes.added)，变更 \(changes.changed)，已匹配海报 \(confirmed.count) 部影视。"
            diagnostics.record("媒体扫描完成：\(candidates.count) 个视频；新增 \(changes.added)、变更 \(changes.changed)、已匹配 \(confirmed.count)")
        } catch is CancellationError {
            message = "扫描已取消。"
        } catch {
            message = error.localizedDescription
            diagnostics.recordError(error, context: "媒体扫描")
        }
    }

    private func autoMatchUnmatched() async {
        let unconfirmed = candidates.filter { !confirmedIDs.contains($0.file.fileId) }
        guard !unconfirmed.isEmpty else { return }

        // Group unconfirmed items by parsed series/movie title
        let groups = Dictionary(grouping: unconfirmed, by: { "\($0.parsedName.mediaType.rawValue):\($0.parsedName.title.lowercased())" })
        var matchedTitlesCount = 0
        let totalGroups = groups.count
        var groupIndex = 0

        for (_, groupCandidates) in groups {
            groupIndex += 1
            guard let first = groupCandidates.first else { continue }
            statusProgress = "正在自动刮削 TMDB 海报：\(first.parsedName.title) (\(groupIndex)/\(totalGroups))…"

            do {
                let token = tokenStore.effectiveToken()
                let raw = try await TMDBService().search(first.parsedName, apiReadToken: token, language: scraperLanguage)
                let ranked = MediaMatchScorer.rank(raw, for: first.parsedName)

                if let best = ranked.first, best.confidence >= 0.58 {
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
                            genreIDs: best.result.genreIDs
                        )
                        try catalog.confirm(item, accountID: accountID)
                    }
                    matchedTitlesCount += 1
                }
            } catch {
                diagnostics.record("自动刮削 \(first.parsedName.title) 失败：\(error.localizedDescription)")
            }
        }

        if matchedTitlesCount > 0 {
            reloadConfirmed()
            diagnostics.record("自动刮削完成：成功匹配 \(matchedTitlesCount) 部影视")
        }
    }

    private func reloadConfirmed() {
        do {
            confirmed = try catalog.confirmed(accountID: accountID)
        } catch {
            message = error.localizedDescription
        }
    }

    @ViewBuilder
    private func poster(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w500\(path)") {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.white.opacity(0.08)).overlay(Image(systemName: "film").font(.largeTitle))
            }
            .frame(height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 330)
                .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
