import SwiftUI

@MainActor
struct MediaItemDetailScreen: View {
    let item: MediaItem
    let related: [MediaItem]
    let candidates: [ScannedMediaCandidate]
    let client: QuarkClient
    let accountID: String
    let history: HistoryRepository
    let tokenStore: TMDBCredentialStore
    let catalog: MediaCatalogRepository
    let diagnostics: Diagnostics
    var onRematched: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var favoriteIDs = Set<String>()
    @State private var selectedFile: CloudFile?
    @State private var showRematchSheet = false
    @State private var selectedSeason: Int = 1
    @State private var watchProgressByFileId: [String: Double] = [:]
    @FocusState private var focusedEpisodeID: String?
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = true

    /// Builds one rematch candidate per confirmed file. Confirmed metadata is
    /// retained as the fallback when the original scanner candidates were not
    /// persisted, so identical names in different season folders keep their
    /// own season/episode context.
    static func rematchCandidates(for related: [MediaItem], candidates: [ScannedMediaCandidate]) -> [ScannedMediaCandidate] {
        let candidateByFileID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.file.fileId, $0) })
        return related.compactMap { metadata in
            let candidate = candidateByFileID[metadata.fileId]
            let file = candidate?.file ?? CloudFile(
                fileId: metadata.fileId,
                parentId: "0",
                name: metadata.title,
                size: 0,
                fileExtension: "mp4",
                modifiedAt: nil,
                isDirectory: false
            )
            let parsed = candidate?.parsedName ?? FilenameParser.parse(
                file.name,
                detectedShowTitle: metadata.title,
                detectedSeasonNumber: metadata.seasonNumber
            )
            let effectiveParsed = ParsedMediaName(
                title: parsed.title,
                year: parsed.year,
                mediaType: metadata.mediaType,
                seasonNumber: metadata.seasonNumber ?? parsed.seasonNumber,
                episodeNumber: metadata.episodeNumber ?? parsed.episodeNumber,
                inferredFromParent: parsed.inferredFromParent
            )
            return TMDBMatchScreen.rematchCandidate(
                for: file,
                parsedName: effectiveParsed,
                candidates: candidates
            )
        }
    }

    private var fileByID: [String: CloudFile] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.file.fileId, $0.file) })
    }

    private var episodes: [(MediaItem, CloudFile, ParsedMediaName)] {
        related.compactMap { metadata in
            let file = fileByID[metadata.fileId] ?? CloudFile(
                fileId: metadata.fileId,
                parentId: "0",
                name: metadata.title,
                size: 0,
                fileExtension: "mp4",
                modifiedAt: nil,
                isDirectory: false
            )
            let cand = candidates.first(where: { $0.file.fileId == metadata.fileId })
            let season = metadata.seasonNumber ?? cand?.parsedName.seasonNumber
            let episode = metadata.episodeNumber ?? cand?.parsedName.episodeNumber
            let parsed = cand?.parsedName ?? FilenameParser.parse(file.name, detectedSeasonNumber: season)
            let effectiveParsed = ParsedMediaName(
                title: parsed.title,
                year: parsed.year,
                mediaType: metadata.mediaType,
                seasonNumber: season ?? parsed.seasonNumber,
                episodeNumber: episode ?? parsed.episodeNumber,
                inferredFromParent: parsed.inferredFromParent
            )
            return (metadata, file, effectiveParsed)
        }.sorted {
            let s0 = $0.2.seasonNumber ?? 0
            let s1 = $1.2.seasonNumber ?? 0
            if s0 != s1 { return s0 < s1 }
            let e0 = $0.2.episodeNumber ?? 0
            let e1 = $1.2.episodeNumber ?? 0
            return e0 < e1
        }
    }

    private var seasonGroups: [Int: [(MediaItem, CloudFile, ParsedMediaName)]] {
        Dictionary(grouping: episodes, by: { $0.2.seasonNumber ?? 1 })
    }

    private var sortedSeasons: [Int] {
        seasonGroups.keys.sorted()
    }

    private var currentSeasonEpisodes: [(MediaItem, CloudFile, ParsedMediaName)] {
        seasonGroups[selectedSeason] ?? episodes
    }

    private var resumeEpisode: (MediaItem, CloudFile, ParsedMediaName)? {
        episodes.first(where: {
            let progress = watchProgressByFileId[$0.1.fileId] ?? 0
            return progress > 0 && progress < 0.95
        }) ?? episodes.first
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.07, blue: 0.10)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                // MARK: - 1. Hero Header
                ZStack(alignment: .bottomLeading) {
                    backdrop(item.backdropPath)

                    HStack(alignment: .bottom, spacing: 40) {
                        poster(item.posterPath)

                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Text(item.title)
                                    .font(.system(size: 46, weight: .bold))
                                SourceBadgeView(type: item.sourceType)
                            }

                            HStack(spacing: 18) {
                                Text(item.year.map(String.init) ?? "年份未知")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)

                                if let rating = item.rating, rating > 0 {
                                    Label(String(format: "%.1f / 10", rating), systemImage: "star.fill")
                                        .font(.headline.bold())
                                        .foregroundStyle(.yellow)
                                }

                                Text(item.mediaType == .series ? "电视剧 · 共 \(episodes.count) 集" : "电影")
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }

                            if let overview = item.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .frame(maxWidth: 1000, alignment: .leading)
                            }

                            // Primary Action Buttons
                            HStack(spacing: 20) {
                                if let target = resumeEpisode {
                                    Button {
                                        selectedFile = target.1
                                    } label: {
                                        let epNum = target.2.episodeNumber ?? 1
                                        let sNum = target.2.seasonNumber ?? 1
                                        let labelText = item.mediaType == .series ? "继续播放 S\(sNum)E\(epNum)" : "播放正片"
                                        Label(labelText, systemImage: "play.fill")
                                            .font(.headline.bold())
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.cyan)
                                }

                                Button {
                                    showRematchSheet = true
                                } label: {
                                    Label("重新匹配 TMDB", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    let isFav = !favoriteIDs.isDisjoint(with: related.map(\.fileId))
                                    setFavorite(!isFav)
                                } label: {
                                    let isFav = !favoriteIDs.isDisjoint(with: related.map(\.fileId))
                                    Label(isFav ? "已收藏" : "加入收藏",
                                          systemImage: isFav ? "heart.fill" : "heart")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    dismiss()
                                } label: {
                                    Label("返回", systemImage: "chevron.left")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 10)
                        }
                        .padding(.bottom, 24)
                    }
                    .padding(.horizontal, 60)
                }

                // MARK: - 2. TV Series Season Tabs
                if item.mediaType == .series && sortedSeasons.count > 1 {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("分季选择")
                            .font(.title2.bold())
                            .padding(.horizontal, 60)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(sortedSeasons, id: \.self) { season in
                                    let count = seasonGroups[season]?.count ?? 0
                                    let isSelected = selectedSeason == season
                                    SeasonTabButton(season: season, count: count, isSelected: isSelected) {
                                        selectedSeason = season
                                    }
                                }
                            }
                            .padding(.horizontal, 60)
                            .padding(.vertical, 8)
                        }
                    }
                    .focusSection()
                }

                // MARK: - 3. Episodes Grid / Rail
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(item.mediaType == .series ? "第 \(selectedSeason) 季 · 剧集列表" : "播放源文件")
                            .font(.title2.bold())
                        Spacer()
                        Text("共 \(currentSeasonEpisodes.count) 个视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 60)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3), spacing: 24) {
                        ForEach(currentSeasonEpisodes, id: \.1.fileId) { entry in
                            episodeCard(entry.0, file: entry.1, parsed: entry.2)
                        }
                    }
                    .padding(.horizontal, 60)
                }
                .focusSection()
            }
            .padding(.bottom, 80)
            }
        }
        .ignoresSafeArea()
        .task {
            favoriteIDs = (try? catalog.favoriteFileIDs(accountID: accountID)) ?? []
            if let firstSeason = sortedSeasons.first {
                selectedSeason = firstSeason
                focusedEpisodeID = seasonGroups[firstSeason]?.first?.1.fileId
            }
            // Load watch history progress
            for ep in episodes {
                if let record = try? history.history(accountID: accountID, fileID: ep.1.fileId),
                   record.durationSeconds > 0 {
                    watchProgressByFileId[ep.1.fileId] = record.positionSeconds / record.durationSeconds
                }
            }
        }
        .onChange(of: selectedSeason) { _, season in
            focusedEpisodeID = seasonGroups[season]?.first?.1.fileId
        }
        .fullScreenCover(item: $selectedFile) { file in
            PlayerScreen(
                client: client,
                accountID: accountID,
                file: file,
                queue: currentSeasonEpisodes.map(\.1),
                automaticallyPlayNext: autoPlayNextEpisode,
                history: history,
                diagnostics: diagnostics
            )
        }
        .sheet(isPresented: $showRematchSheet) {
            TMDBMatchScreen(
                item: item,
                relatedFiles: episodes.map(\.1),
                relatedCandidates: Self.rematchCandidates(for: related, candidates: candidates),
                accountID: accountID,
                tokenStore: tokenStore,
                catalog: catalog,
                diagnostics: diagnostics
            ) {
                onRematched()
                dismiss()
            }
        }
    }

    // MARK: - Episode Card View
    @ViewBuilder
    private func episodeCard(_ metadata: MediaItem, file: CloudFile, parsed: ParsedMediaName) -> some View {
        let epNumber = parsed.episodeNumber ?? 1
        let progress = watchProgressByFileId[file.fileId] ?? 0

        Button {
            selectedFile = file
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.mediaType == .series ? "第 \(epNumber) 集" : "正片")
                        .font(.headline.bold())
                        .foregroundStyle(.cyan)

                    Spacer()

                    Text(file.fileExtension.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }

                Text(file.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 42, alignment: .topLeading)

                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if progress >= 0.95 {
                        Label("已看完", systemImage: "checkmark.circle.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    } else if progress > 0 {
                        Text("看至 \(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                // Progress Bar
                if progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(Color.cyan)
                                .frame(width: geo.size.width * CGFloat(min(1.0, progress)))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.card)
        .focused($focusedEpisodeID, equals: file.fileId)
    }

    private func setFavorite(_ favorite: Bool) {
        do {
            for entry in related { try catalog.setFavorite(accountID: accountID, fileID: entry.fileId, favorite: favorite) }
            favoriteIDs = try catalog.favoriteFileIDs(accountID: accountID)
        } catch { diagnostics.recordError(error, context: "收藏") }
    }

    @ViewBuilder
    private func poster(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w500\(path)") {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color.white.opacity(0.08))
            }
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: 8)
        } else {
            Rectangle().fill(Color.white.opacity(0.08))
                .frame(width: 220, height: 330)
                .overlay(Image(systemName: "film").font(.largeTitle))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private func backdrop(_ path: String?) -> some View {
        ZStack(alignment: .bottom) {
            if let path, let url = URL(string: "https://image.tmdb.org/t/p/w1280\(path)") {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.04))
                }
                .frame(height: 480)
                .clipped()
            } else {
                Rectangle().fill(Color.white.opacity(0.04)).frame(height: 480)
            }

            // Cinematic fade gradients to solid base color
            LinearGradient(
                colors: [.clear, Color(red: 0.05, green: 0.07, blue: 0.10).opacity(0.8), Color(red: 0.05, green: 0.07, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: 480)
    }
}

// MARK: - High-Contrast Focusable Season Tab Button (BUG-001, BUG-008)
private struct SeasonTabButton: View {
    let season: Int
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("第 \(season) 季")
                    .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                Text("(\(count)集)")
                    .font(.subheadline)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.7) : (isSelected ? Color.cyan.opacity(0.8) : Color.secondary))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(
                Group {
                    if isFocused {
                        Color.white
                    } else if isSelected {
                        Color.cyan.opacity(0.25)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .foregroundStyle(isFocused ? Color.black : (isSelected ? Color.cyan : Color.white))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isFocused ? Color.white : (isSelected ? Color.cyan : Color.white.opacity(0.15)),
                        lineWidth: isFocused ? 3 : (isSelected ? 2 : 1)
                    )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}
