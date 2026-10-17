import SwiftUI

@MainActor
struct FileBrowserScreen: View {
    @StateObject private var model: FileBrowserViewModel
    @State private var showPlaybackNotice = false
    @State private var selectedVideo: CloudFile?
    @State private var searchText = ""
    private let accountID: String
    private let history: HistoryRepository?
    private let client: QuarkClient
    private let diagnostics: Diagnostics
    let isMock: Bool

    init(client: QuarkClient, diagnostics: Diagnostics, isMock: Bool, accountID: String,
         history: HistoryRepository?) {
        _model = StateObject(wrappedValue: FileBrowserViewModel(client: client, diagnostics: diagnostics))
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
                        Button("上级目录") { Task { await model.back() } }.disabled(model.isLoading)
                    }
                    Button("刷新") { Task { await model.reload() } }.disabled(model.isLoading)
                }
                HStack(spacing: 16) {
                    TextField("搜索网盘文件名", text: $searchText).frame(maxWidth: 650)
                    Button("搜索") { Task { await model.search(searchText) } }.disabled(model.isLoading)
                    if model.searchQuery != nil {
                        Button("清除搜索") { searchText = ""; Task { await model.clearSearch() } }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if model.files.isEmpty, !model.isLoading, model.errorMessage == nil {
                    Text("此目录暂无文件").foregroundStyle(.secondary)
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
                        }.disabled(model.isLoading)
                    }
                }
                if model.isLoading { ProgressView("正在读取目录") }
                if model.hasMore {
                    Button("加载下一页") { Task { await model.loadMore() } }.disabled(model.isLoading)
                }
            }.padding(60)
        }
        .task { await model.reload() }
        .alert("无法播放此文件", isPresented: $showPlaybackNotice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("当前文件类型不是支持的视频格式。")
        }
        .fullScreenCover(item: $selectedVideo) { file in
            if let history {
                PlayerScreen(client: client, accountID: accountID, file: file,
                             history: history, diagnostics: diagnostics)
            } else {
                Text("无法创建本地观看记录数据库。")
            }
        }
    }

    private func fileDescription(_ file: CloudFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        let type = file.fileExtension.isEmpty ? "文件" : file.fileExtension.uppercased()
        return "\(type) · \(size)"
    }
}
