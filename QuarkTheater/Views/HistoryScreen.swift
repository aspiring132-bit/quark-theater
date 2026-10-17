import SwiftUI

@MainActor
struct HomeContinueWatchingView: View {
    let repository: HistoryRepository
    let accountID: String
    let client: QuarkClient
    let diagnostics: Diagnostics
    @State private var records: [WatchHistory] = []
    @State private var selectedFile: CloudFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("继续观看").font(.title2.bold())
            if records.isEmpty { Text("还没有未看完的视频").foregroundStyle(.secondary) }
            ForEach(records.prefix(5)) { item in
                Button {
                    selectedFile = CloudFile(fileId: item.fileId, parentId: "0", name: item.displayName,
                        size: 0, fileExtension: (item.displayName as NSString).pathExtension, modifiedAt: nil, isDirectory: false)
                } label: {
                    HStack(spacing: 20) {
                        Image(systemName: "play.circle.fill").foregroundStyle(.cyan).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            if item.fileName != nil {
                                Text("ID: \(item.fileId.prefix(12))…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(Int(item.positionSeconds)) / \(Int(item.durationSeconds)) 秒").foregroundStyle(.secondary)
                    }.padding(14)
                }
            }
        }
        .task { reload() }
        .fullScreenCover(item: $selectedFile) { file in
            PlayerScreen(client: client, accountID: accountID, file: file,
                         history: repository, diagnostics: diagnostics)
        }
    }

    private func reload() {
        records = (try? repository.recent(accountID: accountID).filter { !$0.completed }) ?? []
    }
}

@MainActor
struct HistoryScreen: View {
    let repository: HistoryRepository
    let accountID: String
    let client: QuarkClient
    let diagnostics: Diagnostics
    @State private var records: [WatchHistory] = []
    @State private var errorMessage: String?
    @State private var showClearConfirmation = false
    @State private var selectedFile: CloudFile?

    private var inProgress: [WatchHistory] { records.filter { !$0.completed } }
    private var completed: [WatchHistory] { records.filter(\.completed) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("观看历史").font(.largeTitle.bold())
                    Spacer()
                    Button("清空此账号历史", role: .destructive) { showClearConfirmation = true }
                        .disabled(records.isEmpty)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                section("继续观看", items: inProgress)
                section("已看完", items: completed)
                if records.isEmpty && errorMessage == nil { Text("还没有观看记录").foregroundStyle(.secondary) }
            }.frame(maxWidth: 1400, alignment: .leading).padding(60)
        }
        .task(id: accountID) { reload() }
        .fullScreenCover(item: $selectedFile) { file in
            PlayerScreen(client: client, accountID: accountID, file: file,
                         history: repository, diagnostics: diagnostics)
        }
        .confirmationDialog("清空当前账号的观看记录？", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("清空历史", role: .destructive) {
                do { try repository.clear(accountID: accountID); reload() }
                catch { errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder private func section(_ title: String, items: [WatchHistory]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.title2.bold())
                ForEach(items) { item in
                    HStack(spacing: 24) {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "play.circle.fill")
                            .font(.title2).foregroundStyle(item.completed ? .green : .cyan)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(item.completed ? "已看完" : "\(Int(item.positionSeconds)) / \(Int(item.durationSeconds)) 秒")
                                .foregroundStyle(.secondary)
                            Text(item.lastWatchedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !item.completed {
                            Button("继续观看") {
                                selectedFile = CloudFile(fileId: item.fileId, parentId: "0", name: item.displayName,
                                    size: 0, fileExtension: (item.displayName as NSString).pathExtension, modifiedAt: nil, isDirectory: false)
                            }
                        }
                        Button("删除") { remove(item) }
                    }.padding(12)
                    Divider()
                }
            }
        }
    }

    private func reload() {
        do { records = try repository.recent(accountID: accountID); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func remove(_ item: WatchHistory) {
        do { try repository.delete(accountID: accountID, fileID: item.fileId); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}
