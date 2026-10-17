import SwiftUI

@MainActor
struct TMDBMatchScreen: View {
    let candidate: ScannedMediaCandidate?
    let existingItem: MediaItem?
    let relatedFiles: [CloudFile]
    let accountID: String
    let tokenStore: TMDBCredentialStore
    let catalog: MediaCatalogRepository
    let diagnostics: Diagnostics
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var queryText: String
    @State private var selectedMediaType: MediaType
    @State private var results: [ScoredTMDBResult] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedID: Int?
    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"

    init(candidate: ScannedMediaCandidate, accountID: String, tokenStore: TMDBCredentialStore,
         catalog: MediaCatalogRepository, diagnostics: Diagnostics, onSaved: @escaping () -> Void) {
        self.candidate = candidate
        self.existingItem = nil
        self.relatedFiles = [candidate.file]
        self.accountID = accountID
        self.tokenStore = tokenStore
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.onSaved = onSaved
        _queryText = State(initialValue: candidate.parsedName.title)
        _selectedMediaType = State(initialValue: candidate.parsedName.mediaType)
    }

    init(item: MediaItem, relatedFiles: [CloudFile], accountID: String, tokenStore: TMDBCredentialStore,
         catalog: MediaCatalogRepository, diagnostics: Diagnostics, onSaved: @escaping () -> Void) {
        self.candidate = nil
        self.existingItem = item
        self.relatedFiles = relatedFiles
        self.accountID = accountID
        self.tokenStore = tokenStore
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.onSaved = onSaved
        _queryText = State(initialValue: item.title)
        _selectedMediaType = State(initialValue: item.mediaType)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(existingItem != nil ? "重新匹配影视信息" : "匹配 TMDB 影视信息")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text(displayName).foregroundStyle(.secondary)
                    if relatedFiles.count > 1 {
                        Text("将同时为当前全部 \(relatedFiles.count) 个分集应用此匹配").font(.caption).foregroundStyle(.cyan)
                    }
                }

                HStack(spacing: 16) {
                    TextField("输入影视名称搜索", text: $queryText)
                        .frame(maxWidth: 550)
                    Picker("类型", selection: $selectedMediaType) {
                        Text("电影").tag(MediaType.movie)
                        Text("电视剧").tag(MediaType.series)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)

                    Button("搜索") {
                        Task { await search() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if loading {
                    ProgressView("正在向 TMDB 搜索海报与信息…")
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.orange)
                }

                if !results.isEmpty {
                    Text("搜索候选（点击选择）").font(.title3.bold())
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                        ForEach(results, id: \.result.id) { match in
                            let isSelected = selectedID == match.result.id
                            Button {
                                selectedID = match.result.id
                            } label: {
                                HStack(spacing: 20) {
                                    posterThumb(match.result.posterPath)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(match.result.displayTitle)
                                            .font(.headline)
                                            .lineLimit(2)
                                        Text("\(match.result.year.map(String.init) ?? "年份未知") · 置信度 \(Int(match.confidence * 100))%")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let overview = match.result.overview, !overview.isEmpty {
                                            Text(overview)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.cyan)
                                            .font(.title2)
                                    }
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isSelected ? Color.cyan.opacity(0.15) : Color.white.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                                )
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                if let chosen = results.first(where: { $0.result.id == selectedID }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(chosen.confidence < 0.82 ? "提示：此项置信度较低，请仔细核对名称与年份。" : "已选中：\(chosen.result.displayTitle)")
                            .font(.callout)
                            .foregroundStyle(chosen.confidence < 0.82 ? .yellow : .secondary)

                        HStack(spacing: 20) {
                            Button {
                                save(chosen)
                            } label: {
                                Label("确认匹配并保存海报", systemImage: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(loading)

                            Button("取消", role: .cancel) { dismiss() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 12)
                } else {
                    Button("关闭", role: .cancel) { dismiss() }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .padding(60)
        }
        .background(Color.black.opacity(0.95).ignoresSafeArea())
        .task { await search() }
    }

    private var displayName: String {
        if let existingItem {
            return "当前匹配：\(existingItem.title) (\(existingItem.year.map(String.init) ?? "未知"))"
        }
        if let candidate {
            return "文件：\(candidate.file.name)"
        }
        return ""
    }

    @ViewBuilder
    private func posterThumb(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w185\(path)") {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.white.opacity(0.08))
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 60, height: 90)
                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func search() async {
        let cleanQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let parsed = ParsedMediaName(title: cleanQuery, year: nil, mediaType: selectedMediaType, seasonNumber: nil, episodeNumber: nil, inferredFromParent: false)
            let token = tokenStore.effectiveToken()
            let raw = try await TMDBService().search(parsed, apiReadToken: token, language: scraperLanguage)
            results = MediaMatchScorer.rank(raw, for: parsed)
            if results.isEmpty {
                errorMessage = "TMDB 未搜索到与“\(cleanQuery)”相关的影视。可尝试输入中文或英文官方片名重新搜索。"
            } else if selectedID == nil {
                selectedID = results.first?.result.id
            }
        } catch {
            errorMessage = error.localizedDescription
            diagnostics.recordError(error, context: "TMDB 搜索")
        }
    }

    private func save(_ match: ScoredTMDBResult) {
        let result = match.result
        let filesToSave = relatedFiles.isEmpty ? (candidate.map { [$0.file] } ?? []) : relatedFiles
        do {
            for file in filesToSave {
                let item = MediaItem(
                    id: file.fileId,
                    fileId: file.fileId,
                    mediaType: selectedMediaType,
                    title: result.displayTitle,
                    year: result.year,
                    tmdbId: result.id,
                    posterPath: result.posterPath,
                    backdropPath: result.backdropPath,
                    overview: result.overview,
                    duration: nil,
                    matchConfidence: match.confidence,
                    rating: result.voteAverage,
                    genreIDs: result.genreIDs
                )
                try catalog.confirm(item, accountID: accountID)
            }
            diagnostics.record("已确认 TMDB 匹配并应用到 \(filesToSave.count) 个文件：\(result.displayTitle)")
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
