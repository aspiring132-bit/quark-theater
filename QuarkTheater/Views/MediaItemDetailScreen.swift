import SwiftUI

@MainActor
struct MediaItemDetailScreen: View {
    let item: MediaItem
    let related: [MediaItem]
    let candidates: [ScannedMediaCandidate]
    let client: QuarkClient
    let accountID: String
    let history: HistoryRepository
    let catalog: MediaCatalogRepository
    let diagnostics: Diagnostics
    @State private var favoriteIDs = Set<String>()
    @State private var selectedFile: CloudFile?
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = false

    private var fileByID: [String: CloudFile] {
        Dictionary(uniqueKeysWithValues: candidates.map { ($0.file.fileId, $0.file) })
    }

    private var episodes: [(MediaItem, CloudFile, ParsedMediaName)] {
        related.compactMap { metadata in
            guard let file = fileByID[metadata.fileId] else { return nil }
            return (metadata, file, FilenameParser.parse(file.name))
        }.sorted {
            if $0.2.seasonNumber != $1.2.seasonNumber { return ($0.2.seasonNumber ?? 0) < ($1.2.seasonNumber ?? 0) }
            return ($0.2.episodeNumber ?? 0) < ($1.2.episodeNumber ?? 0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                backdrop(item.backdropPath)
                HStack(alignment: .top, spacing: 32) {
                    poster(item.posterPath)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(item.title).font(.largeTitle.bold())
                        Text(item.year.map(String.init) ?? "年份未知").font(.title3).foregroundStyle(.secondary)
                        if let rating = item.rating { Label(String(format: "%.1f / 10", rating), systemImage: "star.fill").foregroundStyle(.yellow) }
                        if let overview = item.overview, !overview.isEmpty { Text(overview).font(.title3).fixedSize(horizontal: false, vertical: true) }
                        Text("匹配置信度：\(Int((item.matchConfidence ?? 0) * 100))% · TMDB ID \(item.tmdbId ?? 0)")
                            .foregroundStyle(.secondary)
                        Button(favoriteIDs.isDisjoint(with: related.map(\.fileId)) ? "加入收藏" : "取消收藏") {
                            setFavorite(favoriteIDs.isDisjoint(with: related.map(\.fileId)))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if item.mediaType == .series {
                    Text("分季分集").font(.title2.bold())
                    let seasons = Dictionary(grouping: episodes, by: { $0.2.seasonNumber ?? 0 })
                    ForEach(seasons.keys.sorted(), id: \.self) { season in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("第 \(season) 季").font(.headline)
                            let entries = seasons[season] ?? []
                            ForEach(entries.indices, id: \.self) { index in
                                let entry = entries[index]
                                episodeRow(entry.0, file: entry.1, parsed: entry.2)
                            }
                        }
                    }
                } else {
                    ForEach(episodes.indices, id: \.self) { index in
                        let entry = episodes[index]
                        episodeRow(entry.0, file: entry.1, parsed: entry.2)
                    }
                }
            }.frame(maxWidth: 1500, alignment: .leading).padding(56)
        }
        .task { favoriteIDs = (try? catalog.favoriteFileIDs(accountID: accountID)) ?? [] }
        .fullScreenCover(item: $selectedFile) { file in
            PlayerScreen(client: client, accountID: accountID, file: file,
                         queue: episodes.map(\.1), automaticallyPlayNext: autoPlayNextEpisode,
                         history: history, diagnostics: diagnostics)
        }
    }

    @ViewBuilder
    private func episodeRow(_ metadata: MediaItem, file: CloudFile, parsed: ParsedMediaName) -> some View {
        let episodeCode = String(format: "S%02dE%02d", parsed.seasonNumber ?? 0, parsed.episodeNumber ?? 0)
        Button { selectedFile = file } label: {
            HStack(spacing: 20) {
                Image(systemName: "play.fill").foregroundStyle(.cyan)
                Text(item.mediaType == .series ? episodeCode : "播放")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).lineLimit(1)
                    Text("\(file.fileExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if favoriteIDs.contains(metadata.fileId) { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setFavorite(_ favorite: Bool) {
        do {
            for entry in related { try catalog.setFavorite(accountID: accountID, fileID: entry.fileId, favorite: favorite) }
            favoriteIDs = try catalog.favoriteFileIDs(accountID: accountID)
        } catch { diagnostics.recordError(error, context: "收藏") }
    }

    @ViewBuilder private func poster(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w500\(path)") {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                Rectangle().fill(Color.white.opacity(0.08))
            }.frame(width: 240, height: 360).clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 240, height: 360)
                .overlay(Image(systemName: "film").font(.largeTitle))
        }
    }

    @ViewBuilder private func backdrop(_ path: String?) -> some View {
        if let path, let url = URL(string: "https://image.tmdb.org/t/p/w1280\(path)") {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                Rectangle().fill(Color.white.opacity(0.05))
            }.frame(height: 280).clipped().overlay(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
        }
    }
}
