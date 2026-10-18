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
    let isMock: Bool

    init(client: QuarkClient, diagnostics: Diagnostics, isMock: Bool, accountID: String,
         history: HistoryRepository?) {
        _model = StateObject(wrappedValue: FileBrowserViewModel(client: client, diagnostics: diagnostics, accountID: accountID))
        self.isMock = isMock
        self.accountID = accountID
        self.history = history
        self.client = client
        self.diagnostics = diagnostics
    }

    var body: some View {
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
                        Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await model.reload() }
                        } label: {
                            Label("重新加载网盘", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if model.files.isEmpty, !model.isLoading, model.errorMessage == nil {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("此目录暂无文件").foregroundStyle(.secondary)
                        Button("刷新目录") { Task { await model.reload() } }
                            .buttonStyle(.bordered)
                    }
                }
                LazyVStack(spacing: 20) {
                    ForEach(model.files) { file in
                        Button {
                            if file.isDirectory { Task { await model.open(file) } }
                            else if file.isVideo { selectedVideo = file }
                            else { showPlaybackNotice = true }
                        } label: {
                            HStack(spacing: 28) {
                                Image(systemName: file.isDirectory ? "folder.fill" : (file.isVideo ? "film" : "doc"))
                                    .font(.system(size: 36)).frame(width: 50)
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(file.name).lineLimit(2)
                                    Text(file.isDirectory ? "文件夹" : fileDescription(file)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: file.isDirectory ? "chevron.right" : "info.circle")
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                        .buttonStyle(.bordered)
                        .focused($focusedTarget, equals: .file(file.fileId))
                        .disabled(model.isLoading)
                    }
                }
                if model.isLoading { ProgressView("正在读取目录") }
                if model.hasMore {
                    Button("加载下一页") { Task { await model.loadMore() } }.disabled(model.isLoading)
                }
            }.padding(60)
        }
        .task { await model.reload() }
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
                PlayerScreen(
                    client: client,
                    accountID: accountID,
                    file: file,
                    queue: model.files.filter(\.isVideo),
                    automaticallyPlayNext: autoPlayNextEpisode,
                    history: history,
                    diagnostics: diagnostics
                )
            } else {
                Text("无法创建本地观看记录数据库。")
            }
        }
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
                        .tint(isSelected ? .cyan : nil)
                    }
                    Button {
                        Task { await model.switchToFolder(id: "0", name: "全部网盘根目录") }
                    } label: {
                        Label("全盘根目录", systemImage: "externaldrive")
                    }
                    .buttonStyle(.bordered)
                    .tint(model.folders.last?.id == "0" ? .cyan : nil)
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
