import SwiftUI

enum FolderFocusTarget: Hashable {
    case breadcrumb(Int)
    case folderSelect(String)
    case folderEnter(String)
    case cancel
}

@MainActor
struct FolderSelectionScreen: View {
    let client: QuarkClient
    let accountID: String
    let diagnostics: Diagnostics
    @Binding var isPresented: Bool
    var onComplete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    init(client: QuarkClient, accountID: String, diagnostics: Diagnostics,
         isPresented: Binding<Bool> = .constant(true), onComplete: @escaping () -> Void = {}) {
        self.client = client
        self.accountID = accountID
        self.diagnostics = diagnostics
        self._isPresented = isPresented
        self.onComplete = onComplete
    }

    // Path Stack for deep drill-down navigation (BUG-007, REDESIGN-010)
    @State private var pathStack: [(id: String, name: String)] = [("0", "我的网盘")]
    @State private var availableFolders: [CloudFile] = []
    @State private var boundFoldersMap: [String: String] = [:] // fileId -> folderName
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedTarget: FolderFocusTarget?

    private var currentFolder: (id: String, name: String) {
        pathStack.last ?? ("0", "我的网盘")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("绑定影视媒体库文件夹")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("可逐级进入子文件夹选择影视目录。仅扫描绑定文件夹，大幅提升刮削速度并保持影视库整洁。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // MARK: - Action Toolbar
                HStack(spacing: 20) {
                    Button {
                        saveAndDismiss()
                    } label: {
                        Label(
                            boundFoldersMap.isEmpty ? "进入影院 (全盘扫描)" : "确认绑定并进入影院 (\(boundFoldersMap.count) 个文件夹)",
                            systemImage: "film.stack"
                        )
                        .font(.headline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(isLoading)

                    if pathStack.count > 1 {
                        Button {
                            goBack()
                        } label: {
                            Label("返回上一级", systemImage: "arrow.turn.up.left")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoading)
                    }

                    if currentFolder.id != "0" {
                        let isCurrentBound = boundFoldersMap[currentFolder.id] != nil
                        Button {
                            if isCurrentBound {
                                boundFoldersMap.removeValue(forKey: currentFolder.id)
                            } else {
                                boundFoldersMap[currentFolder.id] = currentFolder.name
                            }
                        } label: {
                            Label(
                                isCurrentBound ? "取消绑定当前目录" : "绑定当前目录 (\(currentFolder.name))",
                                systemImage: isCurrentBound ? "checkmark.circle.fill" : "plus.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoading)
                    }

                    Button("全选本页") {
                        for folder in availableFolders {
                            boundFoldersMap[folder.fileId] = folder.name
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || availableFolders.isEmpty)

                    Button("清空所有已选") {
                        boundFoldersMap.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || boundFoldersMap.isEmpty)

                    Spacer()

                    Button("取消 / 关闭") {
                        isPresented = false
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTarget, equals: .cancel)
                }
                .focusSection()

                // MARK: - Breadcrumb Navigation Bar
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.cyan)
                    Text("当前路径：")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ForEach(pathStack.indices, id: \.self) { index in
                        let item = pathStack[index]
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            if index < pathStack.count - 1, !isLoading {
                                pathStack = Array(pathStack.prefix(index + 1))
                                focusedTarget = .cancel
                                Task { await loadFolders(folderID: currentFolder.id) }
                            }
                        } label: {
                            Text(item.name)
                                .font(index == pathStack.count - 1 ? .headline.bold() : .headline)
                                .foregroundStyle(index == pathStack.count - 1 ? Color.cyan : Color.white)
                        }
                        .buttonStyle(.borderless)
                        .focused($focusedTarget, equals: .breadcrumb(index))
                        .disabled(isLoading || index == pathStack.count - 1)
                    }

                    Spacer()

                    if !boundFoldersMap.isEmpty {
                        Text("已选定 \(boundFoldersMap.count) 个文件夹")
                            .font(.callout.bold())
                            .foregroundStyle(.cyan)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .focusSection()

                // MARK: - Folder Content List / Grid
                if isLoading {
                    HStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("正在读取目录【\(currentFolder.name)】…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                } else if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(error).foregroundStyle(.orange)
                        Button("重试") { Task { await loadFolders(folderID: currentFolder.id) } }
                            .buttonStyle(.bordered)
                    }
                } else if availableFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("当前目录下没有子文件夹。")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        if currentFolder.id != "0" {
                            Text("若本目录包含影视文件，可点击上方“绑定当前目录”将其设为影视库。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                        ForEach(availableFolders) { folder in
                            let isSelected = boundFoldersMap[folder.fileId] != nil
                            FolderItemRow(
                                folder: folder,
                                isSelected: isSelected,
                                onToggleSelect: {
                                    if isSelected {
                                        boundFoldersMap.removeValue(forKey: folder.fileId)
                                    } else {
                                        boundFoldersMap[folder.fileId] = folder.name
                                    }
                                },
                                onEnter: {
                                    enterFolder(folder)
                                },
                                isDisabled: isLoading,
                                focusedTarget: $focusedTarget
                            )
                        }
                    }
                    .focusSection()
                }
            }
            .padding(60)
            .frame(maxWidth: 1600, alignment: .leading)
        }
        .background(Color.black.opacity(0.95).ignoresSafeArea())
        .onChange(of: focusedTarget) { _, target in
            if let target { diagnostics.recordFocusTransition(FocusDiagnostics.target(for: target)) }
        }
        .task {
            let names = BoundFolderStore.boundFolderNames(accountID: accountID)
            let ids = BoundFolderStore.boundFolderIDs(accountID: accountID)
            var map = names
            for id in ids where map[id] == nil {
                map[id] = "影视文件夹"
            }
            boundFoldersMap = map
            await loadFolders(folderID: currentFolder.id)
        }
    }

    private func enterFolder(_ folder: CloudFile) {
        guard !isLoading else { return }
        pathStack.append((id: folder.fileId, name: folder.name))
        // The source row disappears while the child directory is loading. Keep
        // focus on an enabled, persistent control until the new rows exist.
        focusedTarget = .cancel
        Task {
            await loadFolders(folderID: folder.fileId)
        }
    }

    private func goBack() {
        guard pathStack.count > 1, !isLoading else { return }
        pathStack.removeLast()
        // The current breadcrumb is intentionally disabled. Use the persistent
        // close control while loading; loadFolders will move focus to the first
        // child or an enabled ancestor breadcrumb when the result is known.
        focusedTarget = .cancel
        Task {
            await loadFolders(folderID: currentFolder.id)
        }
    }

    private func loadFolders(folderID: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        availableFolders = []
        defer { isLoading = false }
        do {
            let page = try await client.listFiles(parentID: folderID, page: 1, pageSize: 100)
            availableFolders = page.files.filter(\.isDirectory).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if let current = focusedTarget,
               case let .folderSelect(id) = current,
               availableFolders.contains(where: { $0.fileId == id }) {
                focusedTarget = current
            } else if let current = focusedTarget,
                      case let .folderEnter(id) = current,
                      availableFolders.contains(where: { $0.fileId == id }) {
                focusedTarget = current
            } else if let first = availableFolders.first {
                focusedTarget = .folderSelect(first.fileId)
            } else if pathStack.count > 1 {
                // The current breadcrumb is disabled. Focus its enabled parent.
                focusedTarget = .breadcrumb(pathStack.count - 2)
            } else {
                focusedTarget = .cancel
            }

            // Auto pre-select likely media folders on very first launch
            if !BoundFolderStore.hasConfigured(accountID: accountID) && boundFoldersMap.isEmpty && folderID == "0" {
                let mediaKeywords = ["bt", "下载", "影视", "电影", "剧", "视频", "media", "movie", "tv"]
                for folder in availableFolders {
                    let lower = folder.name.lowercased()
                    if mediaKeywords.contains(where: { lower.contains($0) }) {
                        boundFoldersMap[folder.fileId] = folder.name
                    }
                }
            }
        } catch {
            errorMessage = userFacingError(error)
            // Folder rows may have been removed by the failed navigation. The
            // cancel button remains visible and enabled in every state.
            focusedTarget = .cancel
            diagnostics.recordError(error, context: "读取网盘目录 [\(folderID)]")
        }
    }

    private func saveAndDismiss() {
        let list = boundFoldersMap.map { (id: $0.key, name: $0.value) }
        BoundFolderStore.saveBoundFolders(folders: list, accountID: accountID)
        onComplete()
        isPresented = false
        dismiss()
    }
}

// MARK: - Folder Item Row Component with Drill-Down & Selection
@MainActor
private struct FolderItemRow: View {
    let folder: CloudFile
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onEnter: () -> Void
    let isDisabled: Bool
    let focusedTarget: FocusState<FolderFocusTarget?>.Binding

    var body: some View {
        HStack(spacing: 12) {
            // Select / Toggle Button
            Button(action: onToggleSelect) {
                HStack(spacing: 16) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 28))
                        .foregroundStyle(isSelected ? Color.cyan : Color.secondary)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.cyan)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(folder.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(isSelected ? "已选定为影视库 · 点击取消" : "点击选定为影视库")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(isSelected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.cyan : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
                )
            }
            .buttonStyle(.card)
            .focused(focusedTarget, equals: .folderSelect(folder.fileId))
            .disabled(isDisabled)

            // Drill down into subfolder button
            Button(action: onEnter) {
                HStack(spacing: 6) {
                    Text("进入")
                        .font(.subheadline.bold())
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
            }
            .buttonStyle(.bordered)
            .focused(focusedTarget, equals: .folderEnter(folder.fileId))
            .disabled(isDisabled)
        }
    }
}
