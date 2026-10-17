import SwiftUI

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

    @State private var availableFolders: [CloudFile] = []
    @State private var selectedFolderIDs: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("绑定影视媒体库文件夹")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text("请选择包含电影、电视剧的网盘文件夹。仅扫描绑定文件夹，大幅提升刮削速度并保持影视库整洁。")
                        .font(.title3).foregroundStyle(.secondary)
                }

                // Top Controls: "确认绑定" is the FIRST button, so default focus lands here immediately!
                HStack(spacing: 24) {
                    Button {
                        saveAndDismiss()
                    } label: {
                        Label(selectedFolderIDs.isEmpty ? "跳过 (默认扫描全盘)" : "确认绑定 (\(selectedFolderIDs.count) 个文件夹)",
                              systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(isLoading)

                    Button("全选") {
                        selectedFolderIDs = Set(availableFolders.map(\.fileId))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || availableFolders.isEmpty)

                    Button("清除选择") {
                        selectedFolderIDs.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading || selectedFolderIDs.isEmpty)

                    Spacer()

                    Button("取消 / 关闭") {
                        isPresented = false
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                if isLoading {
                    HStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("正在读取网盘目录…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                } else if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(error).foregroundStyle(.orange)
                        Button("重试") { Task { await loadFolders() } }
                            .buttonStyle(.bordered)
                    }
                } else if availableFolders.isEmpty {
                    Text("网盘根目录未检测到文件夹，可直接使用全盘扫描。").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], spacing: 24) {
                        ForEach(availableFolders) { folder in
                            let isSelected = selectedFolderIDs.contains(folder.fileId)
                            FolderCardButton(folder: folder, isSelected: isSelected) {
                                if isSelected {
                                    selectedFolderIDs.remove(folder.fileId)
                                } else {
                                    selectedFolderIDs.insert(folder.fileId)
                                }
                            }
                        }
                    }
                }
            }
            .padding(60)
            .frame(maxWidth: 1500, alignment: .leading)
        }
        .background(Color.black.opacity(0.95).ignoresSafeArea())
        .task {
            selectedFolderIDs = BoundFolderStore.boundFolderIDs(accountID: accountID)
            await loadFolders()
        }
    }

    private func loadFolders() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await client.listFiles(parentID: "0", page: 1, pageSize: 100)
            availableFolders = page.files.filter(\.isDirectory)
            // If user has never bound any folders, pre-select folders that look like media (e.g. BT, 视频, 影视)
            if !BoundFolderStore.hasConfigured(accountID: accountID) && selectedFolderIDs.isEmpty {
                let mediaKeywords = ["bt", "下载", "影视", "电影", "剧", "视频", "media", "movie", "tv"]
                for folder in availableFolders {
                    let lower = folder.name.lowercased()
                    if mediaKeywords.contains(where: { lower.contains($0) }) {
                        selectedFolderIDs.insert(folder.fileId)
                    }
                }
            }
        } catch {
            errorMessage = userFacingError(error)
            diagnostics.recordError(error, context: "读取绑定文件夹列表")
        }
    }

    private func saveAndDismiss() {
        let selectedList = availableFolders.filter { selectedFolderIDs.contains($0.fileId) }.map { ($0.fileId, $0.name) }
        BoundFolderStore.saveBoundFolders(folders: selectedList, accountID: accountID)
        onComplete()
        isPresented = false
        dismiss()
    }
}

@MainActor
private struct FolderCardButton: View {
    let folder: CloudFile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 32))
                    .foregroundStyle(isSelected ? Color.cyan : Color.secondary)

                Image(systemName: "folder.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.cyan)

                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(isSelected ? "已选定影视库 · 点击取消" : "未选定 · 点击绑定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.card)
    }
}
