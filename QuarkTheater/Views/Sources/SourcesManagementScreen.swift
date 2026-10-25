import SwiftUI

@MainActor
struct SourcesManagementScreen: View {
    @ObservedObject var model: SessionViewModel
    let client: QuarkClient?
    let accountID: String
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    var onBackToCinema: () -> Void = {}

    @ObservedObject private var repository = SourceRepository.shared
    @State private var selectedSourceID: String?
    @State private var showAddWizard = false

    var body: some View {
        Group {
            if let sourceID = selectedSourceID {
                SourceDetailScreen(
                    repository: repository,
                    sourceID: sourceID,
                    client: client,
                    onDismiss: { selectedSourceID = nil },
                    onScanRequested: { _ in
                        selectedSourceID = nil
                        onBackToCinema()
                    }
                )
            } else {
                sourcesHallView
            }
        }
        .task {
            repository.migrateLegacyQuarkIfNeeded(account: model.account)
        }
    }

    // MARK: - Sources Hall View
    private var sourcesHallView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Top Header Action Bar
                HStack(spacing: 20) {
                    Button(action: onBackToCinema) {
                        Label("返回影院", systemImage: "arrow.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        showAddWizard = true
                    } label: {
                        Label("添加存储来源", systemImage: "plus")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.glassWhite)
                }

                // Title & Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("网盘与存储源管理")
                        .font(.system(size: 42, weight: .bold))
                    Text("统一管理绑定的云盘与局域网 NAS。所有影视资源在【影院】大厅混排聚合呈现，无需手动切换源。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Sources Grid
                let sources = repository.allSources()
                if sources.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                        Text("暂无已配置的存储来源")
                            .font(.title3.bold())
                        Text("点击上方【添加存储来源】即可挂载 WebDAV 或关联云盘。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(60)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], spacing: 28) {
                        ForEach(sources) { source in
                            sourceCard(source)
                        }
                    }
                    .focusSection()
                }

                // Cloud File Browser Section (Quark compatibility)
                if let client {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("网盘文件目录浏览")
                            .font(.title2.bold())
                        FileBrowserScreen(
                            client: client,
                            diagnostics: model.diagnostics,
                            isMock: model.isMock,
                            accountID: accountID,
                            history: history,
                            catalog: mediaCatalog
                        )
                    }
                    .padding(.top, 24)
                    .focusSection()
                }
            }
            .padding(60)
        }
        .focusSection()
        .onExitCommand(perform: onBackToCinema)
        .sheet(isPresented: $showAddWizard) {
            AddSourceWizardScreen(
                repository: repository,
                currentClient: client,
                currentAccount: model.account,
                isPresented: $showAddWizard
            )
        }
    }

    // MARK: - Source Card
    private func sourceCard(_ source: StorageSource) -> some View {
        Button {
            selectedSourceID = source.id
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: source.type.iconName)
                        .font(.title)
                        .foregroundStyle(BrandPalette.iceBlue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName)
                            .font(.title3.bold())
                        if let hint = source.accountHint {
                            Text(hint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text(source.status.displayText)
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(source.status.isOperational ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(source.status.isOperational ? Color.green : Color.orange)
                }

                let count = source.boundFolderIDs.count
                Text(count > 0 ? "已绑定 \(count) 个影视文件夹并参与自动刮削" : "已连接 · 扫描根目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    SourceBadgeView(type: source.type)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
