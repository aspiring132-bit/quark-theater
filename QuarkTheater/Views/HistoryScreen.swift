import SwiftUI

enum HistoryFocusReducer {
    static func successor(after fileID: String, in records: [WatchHistory]) -> String? {
        guard let index = records.firstIndex(where: { $0.fileId == fileID }) else { return records.first?.fileId }
        if index + 1 < records.count { return records[index + 1].fileId }
        if index > 0 { return records[index - 1].fileId }
        return nil
    }
}

@MainActor
struct HomeContinueWatchingView: View {
    let repository: HistoryRepository
    let accountID: String
    let client: QuarkClient
    let diagnostics: Diagnostics
    @State private var records: [WatchHistory] = []
    @State private var selectedFile: CloudFile?

    var body: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("继续观看")
                        .font(.title2.bold())
                    Spacer()
                    Text("自动保存进度 · 一键续播")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(records.prefix(8)) { item in
                            Button {
                                selectedFile = CloudFile(
                                    fileId: item.fileId,
                                    parentId: "0",
                                    name: item.displayName,
                                    size: 0,
                                    fileExtension: (item.displayName as NSString).pathExtension,
                                    modifiedAt: nil,
                                    isDirectory: false
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.cyan)
                                        Spacer()
                                        SourceBadgeView(type: .quark)
                                    }

                                    Text(item.displayName)
                                        .font(.headline)
                                        .lineLimit(1)

                                    Spacer()

                                    let progress = item.durationSeconds > 0 ? (item.positionSeconds / item.durationSeconds) : 0
                                    HStack {
                                        Text("已看至 \(Int(progress * 100))%")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(formatDuration(item.positionSeconds)) / \(formatDuration(item.durationSeconds))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    // Progress Bar
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.white.opacity(0.15))
                                            Capsule().fill(Color.cyan)
                                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.05, progress))))
                                        }
                                    }
                                    .frame(height: 4)
                                }
                                .padding(16)
                                .frame(width: 320, height: 130)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .task { reload() }
            .fullScreenCover(item: $selectedFile) { file in
                PlayerScreen(client: client, accountID: accountID, file: file,
                             history: repository, diagnostics: diagnostics)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func reload() {
        records = (try? repository.recent(accountID: accountID).filter { !$0.completed && $0.positionSeconds > 5 }) ?? []
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
    @FocusState private var focusedFileID: String?

    private var inProgress: [WatchHistory] { records.filter { !$0.completed } }
    private var completed: [WatchHistory] { records.filter(\.completed) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text("观看历史").font(.largeTitle.bold())
                    Spacer()
                    Button("清空此账号历史", role: .destructive) { showClearConfirmation = true }
                        .focused($focusedFileID, equals: "__history_toolbar__")
                        .disabled(records.isEmpty)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                section("继续观看", items: inProgress)
                section("已看完", items: completed)
                if records.isEmpty && errorMessage == nil { Text("还没有观看记录").foregroundStyle(.secondary) }
            }.frame(maxWidth: 1400, alignment: .leading).padding(60)
        }
        .task(id: accountID) { reload() }
        .onChange(of: focusedFileID) { _, target in
            if target == "__history_toolbar__" {
                diagnostics.recordFocusTransition(.historyToolbar)
            } else if target != nil {
                diagnostics.recordFocusTransition(.historyRow)
            }
        }
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
                            .focused($focusedFileID, equals: item.fileId)
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
            let nextFocus = HistoryFocusReducer.successor(after: item.fileId, in: records)
            do {
                try repository.delete(accountID: accountID, fileID: item.fileId)
                reload()
                focusedFileID = nextFocus ?? (records.isEmpty ? "__history_toolbar__" : records[0].fileId)
            }
        catch { errorMessage = error.localizedDescription }
    }
}
