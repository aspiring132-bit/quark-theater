import SwiftUI

@MainActor
struct SourceDetailScreen: View {
    @ObservedObject var repository: SourceRepository = .shared
    let sourceID: String
    let client: QuarkClient?
    var onDismiss: () -> Void = {}
    var onScanRequested: (StorageSource) -> Void = { _ in }

    @State private var source: StorageSource?
    @State private var showFolderBrowser = false
    @State private var showRenameAlert = false
    @State private var newDisplayName = ""
    @State private var confirmRemove = false
    @State private var isTesting = false
    @State private var testResult: SourceConnectionStatus?

    var body: some View {
        ScrollView {
            if let currentSource = source {
                VStack(alignment: .leading, spacing: 32) {
                    headerBar
                    sourceHeader(currentSource)
                    actionsSection(currentSource)
                    destructiveSection
                }
                .frame(maxWidth: 1300, alignment: .leading)
                .padding(60)
            } else {
                ProgressView().padding(60)
            }
        }
        .onExitCommand(perform: onDismiss)
        .confirmationDialog(
            "确定解除绑定此存储源？",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("确认移除", role: .destructive) {
                removeSource()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清除 Apple TV 本机连接与凭据，网盘与 NAS 上的原始文件绝不受影响。")
        }
        .alert("修改来源别名", isPresented: $showRenameAlert) {
            TextField("来源别名", text: $newDisplayName)
            Button("保存") {
                renameSource()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showFolderBrowser) {
            if let source, let adapter = repository.adapter(for: source.id, client: client) {
                SourceFolderBrowserScreen(
                    source: source,
                    adapter: adapter,
                    isPresented: $showFolderBrowser
                ) { newBoundPaths in
                    var updated = source
                    updated.boundFolderIDs = newBoundPaths
                    try? repository.saveSource(updated)
                    self.source = updated
                }
            }
        }
        .task {
            source = repository.source(id: sourceID)
        }
    }

    private var headerBar: some View {
        HStack {
            Button(action: onDismiss) {
                Label("返回来源列表", systemImage: "arrow.left")
                    .font(.headline.bold())
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    private func sourceHeader(_ currentSource: StorageSource) -> some View {
        HStack(spacing: 24) {
            Image(systemName: currentSource.type.iconName)
                .font(.system(size: 48))
                .foregroundStyle(BrandPalette.iceBlue)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(currentSource.displayName)
                        .font(.largeTitle.bold())

                    SourceBadgeView(type: currentSource.type)

                    Text(currentSource.status.displayText)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(currentSource.status.isOperational ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(currentSource.status.isOperational ? Color.green : Color.orange)
                }

                if let hint = currentSource.accountHint {
                    Text("账号/用户：\(hint)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let url = currentSource.endpointURL {
                    Text("地址：\(url)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionsSection(_ currentSource: StorageSource) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("来源维护与操作").font(.title3.bold())

            HStack(spacing: 20) {
                Button {
                    onScanRequested(currentSource)
                } label: {
                    Label("立即增量扫描", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandPalette.glassWhite)
                .disabled(!currentSource.isEnabled || !currentSource.status.isOperational)

                Button {
                    showFolderBrowser = true
                } label: {
                    Label("管理绑定目录 (\(currentSource.boundFolderIDs.count))", systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.bordered)

                Button {
                    testConnection()
                } label: {
                    Label(isTesting ? "测试中…" : "测试连接", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isTesting)

                Button {
                    newDisplayName = currentSource.displayName
                    showRenameAlert = true
                } label: {
                    Label("重命名别名", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button {
                    toggleEnabled()
                } label: {
                    Label(currentSource.isEnabled ? "停用来源" : "启用来源", systemImage: currentSource.isEnabled ? "pause.circle" : "play.circle")
                }
                .buttonStyle(.bordered)
            }

            if let testResult {
                HStack(spacing: 8) {
                    Image(systemName: testResult == .connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text("连接测试结果：\(testResult.displayText)")
                        .font(.callout.bold())
                }
                .foregroundStyle(testResult == .connected ? .green : .orange)
            }
        }
        .padding(28)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .focusSection()
    }

    private var destructiveSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解除与移除").font(.title3.bold())
            Text("移除此存储来源仅清理 Apple TV 本机保存的接入配置与钥匙串凭据。网盘与 NAS 上的所有原始文件绝不受任何影响。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("移除此存储来源", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.red.opacity(0.15), lineWidth: 1))
        .focusSection()
    }

    private func testConnection() {
        guard let currentSource = source, let adapter = repository.adapter(for: currentSource.id, client: client) else { return }
        isTesting = true
        testResult = nil
        Task {
            let result = (try? await adapter.testConnection()) ?? .unreachable(reason: "连接失败")
            testResult = result
            var updated = currentSource
            updated.status = result
            try? repository.saveSource(updated)
            source = updated
            isTesting = false
        }
    }

    private func toggleEnabled() {
        guard var currentSource = source else { return }
        currentSource.isEnabled.toggle()
        try? repository.saveSource(currentSource)
        source = currentSource
    }

    private func renameSource() {
        guard var currentSource = source else { return }
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            currentSource.displayName = trimmed
            try? repository.saveSource(currentSource)
            source = currentSource
        }
    }

    private func removeSource() {
        try? repository.removeSource(id: sourceID)
        onDismiss()
    }
}
