import SwiftUI

enum FileBrowserFocusTarget: Hashable {
    case search
    case header
    case file(String)
}

@MainActor
struct FileBrowserScreen: View {
    @StateObject private var model: FileBrowserViewModel
    @State private var showPlaybackNotice = false
    @State private var selectedVideo: CloudFile?
    @State private var searchText = ""
    @FocusState private var focusedTarget: FileBrowserFocusTarget?
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = false
    private let accountID: String
    private let history: HistoryRepository?
    private let client: QuarkClient
    private let diagnostics: Diagnostics
    private let catalog: MediaCatalogRepository?
    @State private var confirmedMetadataByFileID: [String: MediaItem] = [:]
    let isMock: Bool

    init(client: QuarkClient, diagnostics: Diagnostics, isMock: Bool, accountID: String,
         history: HistoryRepository?, catalog: MediaCatalogRepository? = nil) {
        _model = StateObject(wrappedValue: FileBrowserViewModel(client: client, diagnostics: diagnostics, accountID: accountID))
        self.isMock = isMock
        self.accountID = accountID
        self.history = history
        self.client = client
        self.diagnostics = diagnostics
        self.catalog = catalog
    }

    var body: some View {
        let showEmptyState = model.files.isEmpty && !model.isLoading && model.errorMessage == nil
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.title).font(.largeTitle.bold())
                        if isMock { Text("MOCK · 模拟文件，不是你的网盘").foregroundStyle(.yellow) }
                        Text("已加载 \(model.files.count) 项\(model.total.map { " / 共 \($0) 项" } ?? "")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canGoBack {
                        Button("上级目录") { Task { await model.back() } }
                            .buttonStyle(.bordered)
                            .disabled(model.isLoading)
                    }
                    Button("刷新") { Task { await model.reload() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoading)
                }
                .focusSection()

                boundFolderSwitcher
                HStack(spacing: 16) {
                    TextField("搜索网盘文件名", text: $searchText)
                        .frame(maxWidth: 650)
                        .focused($focusedTarget, equals: .search)
                    Button("搜索") { Task { await model.search(searchText) } }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoading)
                    if model.searchQuery != nil {
                        Button("清除搜索") { searchText = ""; Task { await model.clearSearch() } }
                            .buttonStyle(.bordered)
                    }
                }
                if let error = model.errorMessage {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(verbatim: error)
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await model.reload() }
                        } label: {
                            Label("重新加载网盘", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if showEmptyState {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("此目录暂无文件").foregroundStyle(.secondary)
                        Button("刷新目录") { Task { await model.reload() } }
                            .buttonStyle(.bordered)
                    }
                }
                LazyVStack(spacing: 20) {
                    ForEach(model.files) { file in
                        fileRow(file)
                    }
                }
                if model.isLoading { ProgressView("正在读取目录") }
                if model.hasMore {
                    Button("加载下一页") { Task { await model.loadMore() } }.disabled(model.isLoading)
                }
            }.padding(60)
        }
        .task { await model.reload() }
        .task(id: accountID) {
            guard let catalog else { return }
            confirmedMetadataByFileID = (try? catalog.confirmed(accountID: accountID))
                .map { Dictionary(uniqueKeysWithValues: $0.map { ($0.fileId, $0) }) } ?? [:]
        }
        .onChange(of: focusedTarget) { _, target in
            if let target { diagnostics.recordFocusTransition(FocusDiagnostics.target(for: target)) }
        }
        .onChange(of: model.files) { _, files in
            guard !files.isEmpty else {
                focusedTarget = .search
                return
            }
            if case let .file(id) = focusedTarget, files.contains(where: { $0.fileId == id }) { return }
            focusedTarget = .file(files[0].fileId)
        }
        .alert("无法播放此文件", isPresented: $showPlaybackNotice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("当前文件类型不是支持的视频格式。")
        }
        .fullScreenCover(item: $selectedVideo) { file in
            if let history {
                let projection = directProjection(for: file)
                PlayerScreen(
                    client: client,
                    accountID: accountID,
                    file: file,
                    queue: projection.queue,
                    automaticallyPlayNext: autoPlayNextEpisode,
                    history: history,
                    diagnostics: diagnostics,
                    episodeMetadataByFileID: projection.metadata
                )
            } else {
                Text("无法创建本地观看记录数据库。")
            }
        }
    }

    private func directProjection(for selected: CloudFile) -> (queue: [CloudFile], metadata: [String: ParsedMediaName]) {
        let videos = model.files.filter(\.isVideo)
        let path = model.folders.map(\.name)
        let metadata = Dictionary(uniqueKeysWithValues: videos.map {
            let parsed = FilenameParser.parse($0.name, pathComponents: path, boundRootName: model.title)
            return ($0.fileId, confirmedMetadataByFileID[$0.fileId].map { EpisodeMetadataProjection.project(metadata: $0, parsed: parsed) } ?? parsed)
        })
        return (PlaybackQueueProjection.directQueue(files: videos, selected: selected, metadata: metadata,
                                                     confirmed: confirmedMetadataByFileID), metadata)
    }

    private func fileRow(_ file: CloudFile) -> some View {
        let iconName = file.isDirectory ? "folder.fill" : (file.isVideo ? "film" : "doc")
        let detail = file.isDirectory ? "文件夹" : fileDescription(file)
        let trailingIcon = file.isDirectory ? "chevron.right" : "info.circle"
        return Button {
            if file.isDirectory { Task { await model.open(file) } }
            else if file.isVideo { selectedVideo = file }
            else { showPlaybackNotice = true }
        } label: {
            HStack(spacing: 28) {
                Image(systemName: iconName).font(.system(size: 36)).frame(width: 50)
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: file.name).lineLimit(2)
                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: trailingIcon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .buttonStyle(.bordered)
        .focused($focusedTarget, equals: .file(file.fileId))
        .disabled(model.isLoading)
    }

    @ViewBuilder
    private var boundFolderSwitcher: some View {
        let boundNames = BoundFolderStore.boundFolderNames(accountID: accountID)
        if !boundNames.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Text("快速切换:").font(.caption).foregroundStyle(.secondary)
                    ForEach(boundNames.keys.sorted(), id: \.self) { fid in
                        let name = boundNames[fid] ?? fid
                        let isSelected = model.folders.last?.id == fid
                        Button {
                            Task { await model.switchToFolder(id: fid, name: name) }
                        } label: {
                            Label(name, systemImage: isSelected ? "folder.fill" : "folder")
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelected ? BrandPalette.glassWhite : nil)
                    }
                    Button {
                        Task { await model.switchToFolder(id: "0", name: "全部网盘根目录") }
                    } label: {
                        Label("全盘根目录", systemImage: "externaldrive")
                    }
                    .buttonStyle(.bordered)
                    .tint(model.folders.last?.id == "0" ? BrandPalette.glassWhite : nil)
                }
            }
        }
    }

    private func fileDescription(_ file: CloudFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let type = file.fileExtension.isEmpty ? "文件" : file.fileExtension.uppercased()
        return "\(type) · \(size)"
    }
}
