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
    @State private var category = "all"
    @State private var sortMode = "name"
    @State private var searchText = ""
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scannedCount = 0
    @State private var message: String?

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
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("媒体库").font(.largeTitle.bold())
                        Text("电影与剧集候选：\(candidates.count) · 已确认匹配：\(confirmed.count)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isScanning ? "取消扫描" : "重新扫描网盘") {
                        if isScanning { scanTask?.cancel() }
                        else { scanTask = Task { await scan() } }
                    }
                }
                if isScanning { ProgressView("正在扫描，已检查 \(scannedCount) 个文件") }
                if let message { Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if candidates.isEmpty && !isScanning { Text("按“重新扫描网盘”读取视频文件。扫描会遍历目录和分页。").foregroundStyle(.secondary) }
                HStack(spacing: 20) {
                    TextField("搜索媒体库", text: $searchText).frame(maxWidth: 500)
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
                if !posterItems.isEmpty {
                    Text("已匹配").font(.title2.bold())
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
                if !unmatchedCandidates.isEmpty { Text("待匹配").font(.title2.bold()) }
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
                            Text("匹配 TMDB").foregroundStyle(.cyan)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
            }.frame(maxWidth: 1500, alignment: .leading).padding(60)
        }
        .task { reloadConfirmed() }
        .onDisappear { scanTask?.cancel() }
        .sheet(item: $activeSheet) { route in
            switch route {
            case .match(let candidate):
                TMDBMatchScreen(candidate: candidate, accountID: accountID, tokenStore: tokenStore,
                    catalog: catalog, diagnostics: diagnostics) { reloadConfirmed() }
            case .detail(let item):
                let related = confirmed.filter { $0.tmdbId == item.tmdbId && $0.mediaType == item.mediaType }
                MediaItemDetailScreen(item: item, related: related, candidates: candidates,
                    client: client, accountID: accountID, history: history,
                    catalog: catalog, diagnostics: diagnostics)
            }
        }
    }

    private func scan() async {
        isScanning = true; scannedCount = 0; message = nil
        defer { isScanning = false }
        do {
            candidates = try await MediaLibraryScanner().scan(client: client) { scannedCount = $0 }
            let changes = try catalog.reconcileScan(accountID: accountID, candidates: candidates)
            reloadConfirmed()
            message = "扫描完成：新增 \(changes.added)，变更 \(changes.changed)，已删除 \(changes.removed)，共 \(candidates.count) 个视频。"
            diagnostics.record("媒体扫描完成：\(candidates.count) 个视频；新增 \(changes.added)、变更 \(changes.changed)、删除 \(changes.removed)")
        } catch is CancellationError { message = "扫描已取消。" }
        catch { message = error.localizedDescription; diagnostics.recordError(error, context: "媒体扫描") }
    }

    private func reloadConfirmed() {
        do { confirmed = try catalog.confirmed(accountID: accountID) }
        catch { message = error.localizedDescription }
    }

    @ViewBuilder private func poster(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w500\(path)") {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                Rectangle().fill(Color.white.opacity(0.08)).overlay(Image(systemName: "film").font(.largeTitle))
            }.frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 330)
                .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
private struct TMDBMatchScreen: View {
    let candidate: ScannedMediaCandidate
    let accountID: String
    let tokenStore: TMDBCredentialStore
    let catalog: MediaCatalogRepository
    let diagnostics: Diagnostics
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var results: [ScoredTMDBResult] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedID: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("匹配影视信息").font(.largeTitle.bold())
                Text("文件：\(candidate.file.name)").foregroundStyle(.secondary)
                if loading { ProgressView("正在搜索 TMDB") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                ForEach(results, id: \.result.id) { match in
                    Button { selectedID = match.result.id } label: {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(match.result.displayTitle).font(.headline)
                                Text("\(match.result.year.map(String.init) ?? "年份未知") · 置信度 \(Int(match.confidence * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedID == match.result.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let chosen = results.first(where: { $0.result.id == selectedID }) {
                    Text(chosen.confidence < 0.82 ? "低置信度：请核对标题和年份后手动确认。" : "请确认此 TMDB 结果与文件相符。")
                        .foregroundStyle(chosen.confidence < 0.82 ? Color.yellow : Color.secondary)
                    Button("确认此匹配并保存") { save(chosen) }.disabled(loading)
                }
                Button("关闭", role: .cancel) { dismiss() }
            }.frame(maxWidth: 1200, alignment: .leading).padding(56)
        }
        .task { await search() }
    }

    private func search() async {
        loading = true; defer { loading = false }
        do {
            guard let token = try tokenStore.load() else { throw TMDBError.missingAPIKey }
            let raw = try await TMDBService().search(candidate.parsedName, apiReadToken: token)
            results = MediaMatchScorer.rank(raw, for: candidate.parsedName)
            if results.isEmpty { errorMessage = "TMDB 没有返回匹配项。" }
        } catch { errorMessage = error.localizedDescription }
    }

    private func save(_ match: ScoredTMDBResult) {
        let result = match.result
        let item = MediaItem(id: candidate.file.fileId, fileId: candidate.file.fileId,
            mediaType: candidate.parsedName.mediaType, title: result.displayTitle,
            year: result.year, tmdbId: result.id, posterPath: result.posterPath,
            backdropPath: result.backdropPath, overview: result.overview,
            duration: nil, matchConfidence: match.confidence,
            rating: result.voteAverage, genreIDs: result.genreIDs)
        do {
            try catalog.confirm(item, accountID: accountID)
            diagnostics.record("已由用户确认 TMDB 匹配：\(candidate.file.fileId)")
            onSaved(); dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
