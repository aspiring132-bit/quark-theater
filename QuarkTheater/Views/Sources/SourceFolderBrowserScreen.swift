import SwiftUI

@MainActor
struct SourceFolderBrowserScreen: View {
    let source: StorageSource
    let adapter: any StorageSourceAdapter
    @Binding var isPresented: Bool
    var onSaved: ([String]) -> Void = { _ in }

    @State private var pathStack: [(id: String, name: String)] = []
    @State private var items: [CloudFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var boundPaths: [String] = []
    @State private var validationWarning: String?

    private var currentFolder: (id: String, name: String) {
        pathStack.last ?? (defaultRootID, "根目录")
    }

    private var defaultRootID: String {
        source.type == .webdav ? "/" : "0"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Top Header Action Bar
                HStack(spacing: 20) {
                    Button {
                        isPresented = false
                    } label: {
                        Label("取消", systemImage: "xmark")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("管理绑定目录 · \(source.displayName)")
                        .font(.title2.bold())

                    Spacer()

                    Button {
                        saveAndDismiss()
                    } label: {
                        Label("保存绑定 (\(boundPaths.count))", systemImage: "checkmark")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.glassWhite)
                }

                // Breadcrumbs & Current Path
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(pathStack.enumerated()), id: \.offset) { index, crumb in
                                Button {
                                    navigateToCrumb(at: index)
                                } label: {
                                    Text(crumb.name)
                                        .font(.callout.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(index == pathStack.count - 1 ? Color.white.opacity(0.18) : Color.white.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)

                                if index < pathStack.count - 1 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Bind Current Folder Button
                    HStack(spacing: 16) {
                        let isCurrentBound = boundPaths.contains(currentFolder.id)
                        Button {
                            toggleBinding(path: currentFolder.id, name: currentFolder.name)
                        } label: {
                            Label(
                                isCurrentBound ? "已绑定当前目录 (点此解绑)" : "绑定当前目录 [\(currentFolder.name)]",
                                systemImage: isCurrentBound ? "folder.badge.minus" : "folder.badge.plus"
                            )
                            .font(.headline)
                        }
                        .buttonStyle(.bordered)
                        .tint(isCurrentBound ? .orange : BrandPalette.iceBlue)

                        if let warning = validationWarning {
                            Text(warning)
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                .focusSection()

                // Bound Folders Summary Capsule List
                if !boundPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("当前已选定影视目录（将扫描并刮削）：")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(boundPaths, id: \.self) { path in
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.fill")
                                            .font(.caption)
                                        Text(path)
                                            .font(.caption.bold())
                                        Button {
                                            boundPaths.removeAll(where: { $0 == path })
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Directory Contents List
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("正在读取目录内容…").foregroundStyle(.secondary)
                        }
                        .padding(40)
                    } else if let errorMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("目录读取失败：\(errorMessage)").foregroundStyle(.orange)
                            Button("重试") {
                                loadFolder(id: currentFolder.id)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(20)
                    } else {
                        let folders = items.filter { $0.isDirectory }
                        if folders.isEmpty {
                            Text("当前目录下无更多子文件夹。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(30)
                        } else {
                            ForEach(folders) { folder in
                                folderRow(folder)
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(60)
        }
        .onExitCommand {
            if pathStack.count > 1 {
                pathStack.removeLast()
                loadFolder(id: currentFolder.id)
            } else {
                isPresented = false
            }
        }
        .task {
            boundPaths = source.boundFolderIDs
            let rootID = defaultRootID
            pathStack = [(id: rootID, name: source.type == .webdav ? "/" : "根目录")]
            loadFolder(id: rootID)
        }
    }

    // MARK: - Distinct Dual-Action Row (Enter vs Bind)
    private func folderRow(_ file: CloudFile) -> some View {
        let isBound = boundPaths.contains(file.fileId)

        return HStack(spacing: 20) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(BrandPalette.iceBlue)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.headline)
                Text(file.fileId)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Action 1: Bind / Unbind Button
            Button {
                toggleBinding(path: file.fileId, name: file.name)
            } label: {
                Label(isBound ? "已绑定" : "绑定此目录", systemImage: isBound ? "checkmark.circle.fill" : "plus.circle")
                    .font(.callout.bold())
            }
            .buttonStyle(.bordered)
            .tint(isBound ? .green : BrandPalette.glassWhite)

            // Action 2: Enter Subdirectory Button
            Button {
                pathStack.append((id: file.fileId, name: file.name))
                loadFolder(id: file.fileId)
            } label: {
                Label("进入", systemImage: "arrow.right")
                    .font(.callout.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandPalette.glassWhite)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isBound ? Color.green.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func toggleBinding(path: String, name: String) {
        validationWarning = nil
        if boundPaths.contains(path) {
            boundPaths.removeAll(where: { $0 == path })
        } else {
            let result = FolderBindingValidator.validate(newPath: path, existingPaths: boundPaths)
            switch result {
            case .valid:
                boundPaths.append(path)
            case .duplicate, .childOfExisting, .parentOfExisting:
                validationWarning = result.errorMessage
            }
        }
    }

    private func navigateToCrumb(at index: Int) {
        guard index < pathStack.count else { return }
        pathStack = Array(pathStack.prefix(index + 1))
        loadFolder(id: currentFolder.id)
    }

    private func loadFolder(id: String) {
        isLoading = true
        errorMessage = nil
        validationWarning = nil

        Task {
            do {
                let page = try await adapter.listFiles(folderID: id, page: 1, pageSize: 200)
                items = page.files
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func saveAndDismiss() {
        onSaved(boundPaths)
        isPresented = false
    }
}
