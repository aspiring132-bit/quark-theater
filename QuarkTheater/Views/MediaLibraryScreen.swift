import SwiftUI

struct RematchSheetTarget: Identifiable {
    let item: MediaItem
    let files: [CloudFile]
    let candidates: [ScannedMediaCandidate]
    var id: String { item.id }
}

@MainActor
struct MediaLibraryScreen: View {
    let client: QuarkClient
    let accountID: String
    let history: HistoryRepository
    let tokenStore: TMDBCredentialStore
    let catalog: MediaCatalogRepository
    let diagnostics: Diagnostics

    @Environment(\.scenePhase) private var scenePhase
    @State private var candidates: [ScannedMediaCandidate] = []
    @State private var confirmed: [MediaItem] = []
    @State private var focusedItem: MediaItem?
    @FocusState private var focusedPosterID: String?
    @FocusState private var focusedHeroAction: LibraryFocusTarget?
    @FocusState private var focusedFilter: LibraryFocusTarget?

    // Selected item for full Netflix/Apple TV style MediaItemDetailScreen
    @State private var selectedDetailItem: MediaItem?

    // Playback state
    @State private var playingFile: CloudFile?
    @State private var playlistQueue: [CloudFile] = []

    // Modals & sheets
    @State private var rematchTarget: RematchSheetTarget?
    @State private var matchCandidate: ScannedMediaCandidate?
    @State private var showFolderSelection = false

    // Filters & search
    @State private var category = "all"
    @State private var sortMode = "name"
    @State private var searchText = ""

    // Scan state
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var statusProgress = ""
    @State private var message: String?
    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = true

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

    private var fileByID: [String: CloudFile] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.file.fileId, $0.file) })
    }

    private func episodesFor(item: MediaItem) -> [(MediaItem, CloudFile, ParsedMediaName)] {
        let related = confirmed.filter { $0.tmdbId == item.tmdbId && $0.mediaType == item.mediaType }
        let targetList = related.isEmpty ? [item] : related
        return targetList.compactMap { metadata in
            let file = fileByID[metadata.fileId] ?? CloudFile(
                fileId: metadata.fileId,
                parentId: "0",
                name: metadata.title,
                size: 0,
                fileExtension: "mp4",
                modifiedAt: nil,
                isDirectory: false
            )
            let parsed = candidates.first(where: { $0.file.fileId == metadata.fileId })?.parsedName
                ?? ParsedMediaName(title: metadata.title, year: metadata.year, mediaType: metadata.mediaType,
                                   seasonNumber: metadata.seasonNumber, episodeNumber: metadata.episodeNumber,
                                   inferredFromParent: true)
            return (metadata, file, parsed)
        }.sorted {
            if $0.2.seasonNumber != $1.2.seasonNumber {
                return ($0.2.seasonNumber ?? 0) < ($1.2.seasonNumber ?? 0)
            }
            return ($0.2.episodeNumber ?? 0) < ($1.2.episodeNumber ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                // MARK: - 1. Hero Showcase Billboard (Netflix / Apple TV / 爆米花影视 巨幕展台)
                if let active = focusedItem ?? posterItems.first {
                    heroShowcase(item: active)
                }

                // MARK: - 2. Filter & Search Controls
                HStack(spacing: 16) {
                    TextField("搜索片名…", text: $searchText)
                        .frame(width: 260)

                    // Category Filter Pills (High-contrast, never truncated or vertically wrapped)
                    HStack(spacing: 10) {
                        ForEach([("all", "全部"), (MediaType.movie.rawValue, "电影"), (MediaType.series.rawValue, "电视剧")], id: \.0) { tag, title in
                            FilterPillButton(
                                title: title,
                                isSelected: category == tag,
                                minWidth: 88,
                                focusTarget: .filter(tag),
                                focusedTarget: $focusedFilter
                            ) {
                                category = tag
                            }
                        }
                    }

                    // Sort Filter Pills
                    HStack(spacing: 10) {
                        ForEach([("name", "按名称"), ("year", "按年份")], id: \.0) { tag, title in
                            FilterPillButton(
                                title: title,
                                isSelected: sortMode == tag,
                                minWidth: 96,
                                focusTarget: .filter(tag),
                                focusedTarget: $focusedFilter
                            ) {
                                sortMode = tag
                            }
                        }
                    }

                    Spacer()

                    // Quick scan trigger
                    Button {
                        if isScanning {
                            scanTask?.cancel()
                        } else {
                            scanTask = Task { await scan() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isScanning ? "xmark.circle" : "arrow.triangle.2.circlepath")
                            Text(isScanning ? "取消" : "重新刮削")
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            try? catalog.clearAll(accountID: accountID)
                            reloadConfirmed()
                            await scan()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                            Text("清空重刮")
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isScanning)

                    Button {
                        showFolderSelection = true
                    } label: {
                        let count = BoundFolderStore.boundFolderIDs(accountID: accountID).count
                        Label(count > 0 ? "绑定 (\(count))" : "选择文件夹", systemImage: "folder.badge.gearshape")
                            .fixedSize()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 60)
                .focusSection()

                // Continue Watching Row (if any)
                HomeContinueWatchingView(repository: history, accountID: accountID, client: client, diagnostics: diagnostics)
                    .padding(.horizontal, 60)

                // Scanning Progress / Status message
                if isScanning {
                    HStack(spacing: 16) {
                        ProgressView().progressViewStyle(.circular)
                        Text(statusProgress.isEmpty ? "正在扫描网盘文件…" : statusProgress)
                            .font(.callout)
                            .foregroundStyle(.cyan)
                    }
                    .padding(.horizontal, 60)
                }

                if let message {
                    Text(message)
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(.horizontal, 60)
                }

                // MARK: - 3. Matched Posters Grid (海报墙瀑布流)
                if !posterItems.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("全部影视 (\(posterItems.count))")
                                .font(.title2.bold())
                            Spacer()
                            Text("点击查看分季详情 · 遥控器快速直达")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 5), spacing: 32) {
                            ForEach(posterItems) { item in
                                Button {
                                    focusedItem = item
                                    selectedDetailItem = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        posterView(item.posterPath, height: 320)
                                            .overlay(alignment: .topLeading) {
                                                SourceBadgeView(type: item.sourceType)
                                                    .padding(8)
                                            }
                                            .overlay(alignment: .topTrailing) {
                                                if item.mediaType == .series {
                                                    let eps = confirmed.filter { $0.tmdbId == item.tmdbId }
                                                    Text("\(eps.count)集")
                                                        .font(.caption2.bold())
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(.ultraThinMaterial, in: Capsule())
                                                        .padding(8)
                                                }
                                            }

                                        Text(item.title)
                                            .font(.headline)
                                            .lineLimit(1)

                                        HStack {
                                            Text(item.year.map(String.init) ?? "年份未知")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            if let rating = item.rating, rating > 0 {
                                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(.yellow)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.card)
                                .focused($focusedPosterID, equals: item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 60)
                    .focusSection()
                } else if !isScanning {
                    VStack(spacing: 24) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                        Text("媒体库暂无已匹配的影片")
                            .font(.title2.bold())
                        Text("请点击“重新扫描与刮削”开始扫描绑定文件夹，系统将自动匹配海报与剧集。")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Button("立即扫描与刮削") {
                            scanTask = Task { await scan() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(80)
                    .focusSection()
                }

                // MARK: - 4. Unmatched Files (待识别文件)
                if !unmatchedCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("待匹配文件 (\(unmatchedCandidates.count))")
                                .font(.title2.bold())
                            Spacer()
                            Button("批量自动匹配") {
                                Task { await autoMatchUnmatched() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isScanning)
                        }

                        ForEach(unmatchedCandidates) { candidate in
                            Button { matchCandidate = candidate } label: {
                                HStack(spacing: 20) {
                                    Image(systemName: candidate.parsedName.mediaType == .series ? "tv" : "film")
                                        .font(.system(size: 28))
                                        .frame(width: 40)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.parsedName.title).font(.headline)
                                        let epInfo = candidate.parsedName.mediaType == .series
                                            ? "第 \(candidate.parsedName.seasonNumber ?? 1) 季 · 第 \(candidate.parsedName.episodeNumber ?? 1) 集"
                                            : (candidate.parsedName.year.map(String.init) ?? "电影")
                                        Text("\(epInfo) · \(candidate.file.name)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("手动匹配 TMDB").font(.subheadline.bold()).foregroundStyle(.cyan)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 60)
                    .focusSection()
                }
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea(edges: .top)
        .onChange(of: focusedPosterID) { _, newID in
            if let newID, let match = posterItems.first(where: { $0.id == newID }) {
                diagnostics.recordFocusTransition(.mediaPoster)
                withAnimation(.easeInOut(duration: 0.25)) {
                    focusedItem = match
                }
            }
        }
        .onChange(of: focusedHeroAction) { _, action in
            if action != nil { diagnostics.recordFocusTransition(.mediaHeroAction) }
        }
        .onChange(of: focusedFilter) { _, filter in
            if filter != nil { diagnostics.recordFocusTransition(.mediaFilter) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await scan(silent: true)
                }
            }
        }
        .task {
            reloadConfirmed()
            if candidates.isEmpty {
                Task { await scan(silent: true) }
            }
            // Periodic background sync: every 15 minutes, silently check for new cloud files
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                if !Task.isCancelled {
                    await scan(silent: true)
                }
            }
        }
        .onDisappear { scanTask?.cancel() }
        .fullScreenCover(item: $selectedDetailItem) { detailItem in
            let related = confirmed.filter { $0.tmdbId == detailItem.tmdbId && $0.mediaType == detailItem.mediaType }
            MediaItemDetailScreen(
                item: detailItem,
                related: related.isEmpty ? [detailItem] : related,
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
        .fullScreenCover(item: $playingFile) { file in
            PlayerScreen(
                client: client,
                accountID: accountID,
                file: file,
                queue: playlistQueue,
                automaticallyPlayNext: autoPlayNextEpisode,
                history: history,
                diagnostics: diagnostics
            )
        }
        .sheet(item: $matchCandidate) { candidate in
            TMDBMatchScreen(
                candidate: candidate,
                accountID: accountID,
                tokenStore: tokenStore,
                catalog: catalog,
                diagnostics: diagnostics
            ) {
                reloadConfirmed()
            }
        }
        .sheet(item: $rematchTarget) { target in
            TMDBMatchScreen(
                item: target.item,
                relatedFiles: target.files,
                relatedCandidates: target.candidates,
                accountID: accountID,
                tokenStore: tokenStore,
                catalog: catalog,
                diagnostics: diagnostics
            ) {
                reloadConfirmed()
            }
        }
        .sheet(isPresented: $showFolderSelection) {
            FolderSelectionScreen(
                client: client,
                accountID: accountID,
                diagnostics: diagnostics,
                isPresented: $showFolderSelection
            ) {
                Task { await scan() }
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero Showcase Billboard View
    @ViewBuilder
    private func heroShowcase(item: MediaItem) -> some View {
        let episodes = episodesFor(item: item)

        ZStack(alignment: .bottomLeading) {
            // Backdrop Image filling 100% of the hero container from the very top (Y=0)
            backdropView(item.backdropPath ?? item.posterPath)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.25), location: 0),
                            .init(color: .clear, location: 0.28),
                            .init(color: Color(red: 0.04, green: 0.06, blue: 0.09).opacity(0.7), location: 0.75),
                            .init(color: Color(red: 0.04, green: 0.06, blue: 0.09), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.04, green: 0.06, blue: 0.09).opacity(0.92), location: 0),
                            .init(color: Color(red: 0.04, green: 0.06, blue: 0.09).opacity(0.55), location: 0.55),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // Content Overlay
            HStack(alignment: .bottom, spacing: 48) {
                // Left Details Column
                VStack(alignment: .leading, spacing: 18) {
                    // Badges Row
                    HStack(spacing: 12) {
                        Text(item.mediaType == .series ? "电视剧" : "电影")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.cyan)

                        if let year = item.year {
                            Text(String(year))
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }

                        if let rating = item.rating, rating > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f", rating))
                                    .bold()
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }

                        if item.mediaType == .series && !episodes.isEmpty {
                            Text("共 \(episodes.count) 集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let conf = item.matchConfidence {
                            Text("TMDB 刮削 \(Int(conf * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Large Title with Source Badge
                    HStack(spacing: 16) {
                        Text(item.title)
                            .font(.system(size: 46, weight: .black, design: .rounded))
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                        SourceBadgeView(type: item.sourceType)
                    }

                    // Synopsis / Overview
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .lineLimit(3)
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: 820, alignment: .leading)
                    }

                    // Direct Action Buttons
                    HStack(spacing: 20) {
                        // View Details & Seasons Button (Primary focus)
                        Button {
                            selectedDetailItem = item
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .font(.headline)
                                Text("查看详情")
                                    .font(.headline.bold())
                            }
                            .fixedSize()
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .focused($focusedHeroAction, equals: .heroDetails)

                        // 1-Click Quick Play
                        Button {
                            if let first = episodes.first {
                                playlistQueue = episodes.map(\.1)
                                playingFile = first.1
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("直接起播")
                                    .font(.headline)
                            }
                            .fixedSize()
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedHeroAction, equals: .heroPlay)

                        // Rematch Button
                        Button {
                            let episodeCandidates = episodes.map { episode in
                                TMDBMatchScreen.rematchCandidate(
                                    for: episode.1,
                                    parsedName: episode.2,
                                    candidates: candidates
                                )
                            }
                            rematchTarget = RematchSheetTarget(item: item, files: episodes.map(\.1), candidates: episodeCandidates)
                        } label: {
                            Label("重新匹配", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                                .fixedSize()
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedHeroAction, equals: .heroRematch)
                    }

                    // MARK: - Direct Episode Rail for Series (选集速播轨)
                    if item.mediaType == .series && !episodes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("选集速播 · 点击直接全屏起播")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(episodes.indices, id: \.self) { idx in
                                        let ep = episodes[idx]
                                        let epNum = ep.2.episodeNumber ?? (idx + 1)
                                        Button {
                                            playlistQueue = episodes.map(\.1)
                                            playingFile = ep.1
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("第 \(epNum) 集")
                                                    .font(.headline)
                                                Text(ep.1.fileExtension.uppercased())
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.horizontal, 18)
                                            .padding(.vertical, 10)
                                            .frame(minWidth: 100)
                                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.borderless)
                                        .focused($focusedHeroAction, equals: .episode(ep.1.fileId))
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(maxWidth: 880)
                        }
                    }
                }
                .frame(maxWidth: 950, alignment: .leading)

                Spacer()

                // Right Poster Card Preview
                posterView(item.posterPath, height: 360)
                    .frame(width: 240)
                    .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
            }
            .padding(.top, 120)
            .padding(.horizontal, 60)
            .padding(.bottom, 36)
        }
        .frame(height: 700)
        .clipped()
    }

    // MARK: - Backdrop View
    @ViewBuilder
    private func backdropView(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w1280\(path)") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Color(red: 0.08, green: 0.1, blue: 0.14)
                }
            }
        } else {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.08, blue: 0.1), Color(red: 0.04, green: 0.06, blue: 0.09)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Poster View
    @ViewBuilder
    private func posterView(_ path: String?, height: CGFloat = 320) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w500\(path)") {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: height)
                .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Scanning & Automatic TMDB Scraping
    private func scan(silent: Bool = false) async {
        if !silent {
            isScanning = true
            statusProgress = "正在读取绑定文件夹…"
            message = nil
        }
        defer {
            if !silent { isScanning = false }
        }

        do {
            let boundIDs = Array(BoundFolderStore.boundFolderIDs(accountID: accountID))
            let names = BoundFolderStore.boundFolderNames(accountID: accountID)
            let syncService = MediaLibrarySyncService(
                client: client,
                accountID: accountID,
                catalog: catalog,
                tokenStore: tokenStore,
                diagnostics: diagnostics
            )
            let (scanned, result) = try await syncService.sync(
                boundFolderIDs: boundIDs,
                boundFolderNames: names,
                scraperLanguage: scraperLanguage
            ) { progress in
                if !silent { statusProgress = progress }
            }
            candidates = scanned
            reloadConfirmed()
            if !silent {
                message = "扫描与刮削完成：新增 \(result.addedCount)，变更 \(result.changedCount)，已匹配海报 \(confirmed.count) 部影视。"
                diagnostics.record("媒体扫描完成：\(candidates.count) 个视频；新增 \(result.addedCount)、变更 \(result.changedCount)、已匹配 \(confirmed.count)")
            }
        } catch is CancellationError {
            if !silent { message = "扫描已取消。" }
        } catch {
            if !silent { message = error.localizedDescription }
            diagnostics.recordError(error, context: "媒体扫描")
        }
    }

    private func autoMatchUnmatched(silent: Bool = false) async {
        let unconfirmed = candidates.filter {
            !confirmedIDs.contains($0.file.fileId) &&
            $0.parsedName.unresolvedReason == nil &&
            $0.parsedName.mediaType != .unknown &&
            !$0.parsedName.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !unconfirmed.isEmpty else {
            if !silent { message = "当前所有文件均已完成匹配。" }
            return
        }

        if !silent {
            isScanning = true
            message = nil
        }
        defer {
            if !silent { isScanning = false }
        }

        let groups = Dictionary(grouping: unconfirmed, by: { "\($0.parsedName.mediaType.rawValue):\($0.parsedName.title.lowercased())" })
        var matchedTitlesCount = 0
        var failedGroups = 0
        let totalGroups = groups.count
        var groupIndex = 0

        for (_, groupCandidates) in groups {
            groupIndex += 1
            guard let first = groupCandidates.first else { continue }

            // Fast-path: If this series is already confirmed, inherit metadata directly
            let normalizedFirst = MediaAliasResolver.normalizeTitle(first.parsedName.title)
            if first.parsedName.mediaType == .series,
               let existingShow = confirmed.first(where: {
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
                    try? catalog.confirm(item, accountID: accountID)
                    matchedTitlesCount += 1
                }
                continue
            }

            if !silent {
                statusProgress = "正在自动刮削 TMDB：\(first.parsedName.title) (\(groupIndex)/\(totalGroups))…"
            }

            do {
                let token = tokenStore.effectiveToken()
                let learnedRecords = try catalog.learnedAliasRecords(accountID: accountID, mediaType: first.parsedName.mediaType, sourceTitle: first.parsedName.title)
                // TMDBService already expands built-in aliases and query variants.
                // Keep learned expansion bounded to the source title plus one
                // canonical title to avoid multiplicative request amplification.
                var queryTitles = [first.parsedName.title]
                if let canonical = learnedRecords.first?.canonicalTitle,
                   MediaAliasResolver.normalizeTitle(canonical) != MediaAliasResolver.normalizeTitle(first.parsedName.title) {
                    queryTitles.append(canonical)
                }
                var raw: [TMDBSearchResult] = []
                var seen = Set<String>()
                var groupHadRequestFailure = false
                // Search the source title first.  A non-empty but weak result
                // must not suppress a learned canonical fallback: aggregate
                // both successful result sets, then apply the strict margin
                // rule to the combined ranking.
                for variant in queryTitles.prefix(2) {
                    var parsed = first.parsedName
                    parsed = ParsedMediaName(title: variant, year: parsed.year, mediaType: parsed.mediaType,
                                             seasonNumber: parsed.seasonNumber, episodeNumber: parsed.episodeNumber,
                                             inferredFromParent: parsed.inferredFromParent, unresolvedReason: parsed.unresolvedReason)
                    let rows: [TMDBSearchResult]
                    do {
                        rows = try await TMDBService(diagnostics: diagnostics).search(parsed, apiReadToken: token, language: scraperLanguage,
                                                                 parentFolderName: first.parentFolderName, ancestorFolderName: first.ancestorFolderName)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        groupHadRequestFailure = true
                        diagnostics.recordError(error, context: "TMDB 自动刮削请求")
                        continue
                    }
                    for row in rows {
                        let key = "\(row.sourceMediaType?.rawValue ?? "unknown"):\(row.id)"
                        if seen.insert(key).inserted { raw.append(row) }
                    }
                    let provisional = MediaMatchScorer.rank(raw, for: first.parsedName,
                                                            ancestorFolderName: first.ancestorFolderName,
                                                            learnedAliasRecords: learnedRecords)
                    if MediaMatchScorer.mayAutoConfirm(provisional) { break }
                }
                let ranked = MediaMatchScorer.rank(raw, for: first.parsedName,
                                                    ancestorFolderName: first.ancestorFolderName,
                                                    learnedAliasRecords: learnedRecords)

                if raw.isEmpty && groupHadRequestFailure {
                    failedGroups += 1
                }

                if MediaMatchScorer.mayAutoConfirm(ranked), let best = ranked.first {
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
                    matchedTitlesCount += 1
                }
            } catch {
                diagnostics.record("自动刮削 \(first.parsedName.title) 失败：\(error.localizedDescription)")
            }
        }

        if matchedTitlesCount > 0 {
            reloadConfirmed()
            if !silent {
                message = "批量刮削完成：已成功匹配并入库 \(matchedTitlesCount) 部影视海报！"
            }
            diagnostics.record("自动刮削完成：成功匹配 \(matchedTitlesCount) 部影视")
        } else if !silent && failedGroups == totalGroups {
            message = "批量刮削请求失败：请检查网络或 TMDB 配置后重试。"
        } else if !silent {
            message = "批量刮削完成：未找到匹配度更高的海报，可点击单条“手动匹配 TMDB”输入关键字搜索。"
        }
    }

    private func reloadConfirmed() {
        do {
            confirmed = try catalog.confirmed(accountID: accountID)
            if focusedItem == nil || !confirmed.contains(where: { $0.id == focusedItem?.id }) {
                focusedItem = posterItems.first
            }
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - High-Contrast Focusable Filter Pill Button (BUG-004, BUG-008)
private struct FilterPillButton: View {
    let title: String
    let isSelected: Bool
    let minWidth: CGFloat
    let focusTarget: LibraryFocusTarget
    @FocusState.Binding var focusedTarget: LibraryFocusTarget?
    let action: () -> Void

    private var isFocused: Bool { focusedTarget == focusTarget }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(minWidth: minWidth)
                .background(
                    Group {
                        if isFocused {
                            Color.white
                        } else if isSelected {
                            Color.cyan.opacity(0.3)
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                )
                .foregroundStyle(
                    isFocused ? Color.black : (isSelected ? Color.cyan : Color.white.opacity(0.85))
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        isFocused ? Color.white : (isSelected ? Color.cyan : Color.white.opacity(0.12)),
                        lineWidth: isFocused ? 2.5 : (isSelected ? 2 : 1)
                    )
                )
                .scaleEffect(isFocused ? 1.08 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: focusTarget)
    }
}
