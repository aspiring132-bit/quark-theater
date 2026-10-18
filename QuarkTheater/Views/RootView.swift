import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    @State private var selectedTab: RootTab = .media
    @State private var showFolderSelection = false
    @FocusState private var focusedDockTab: RootTab?

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.04, green: 0.06, blue: 0.09)
                .ignoresSafeArea()

            // If not logged in, ALWAYS show cinemaTab (which renders LoginScreen)
            if model.account == nil {
                cinemaTab
            } else {
                // MARK: - 1. Screen Contents (Extends completely to Y=0 top edge)
                Group {
                    switch selectedTab {
                    case .media:
                        cinemaTab
                    case .sources:
                        sourcesTab
                    case .settings:
                        SettingsScreen(
                            model: model,
                            history: history,
                            mediaCatalog: mediaCatalog,
                            onBackToCinema: { selectedTab = .media }
                        )
                        .padding(.top, 110)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // MARK: - 2. Full-Width FocusSection Floating Dock Bar
                dockContainer
            }
        }
        .ignoresSafeArea()
        .modifier(RootBackHandler(isEnabled: RootFocusReducer.shouldConsumeBack(selectedTab)) {
            selectedTab = RootFocusReducer.selectedTabAfterBack(selectedTab)
        })
        .onChange(of: model.account) { _, newAccount in
            if newAccount == nil {
                selectedTab = .media
            }
        }
        .onChange(of: selectedTab) { _, _ in
            focusedDockTab = RootFocusReducer.dockTarget(for: selectedTab)
            model.diagnostics.recordFocusTransition(selectedTab.diagnosticFocusTarget)
        }
        .task {
            UserDefaults.standard.removeObject(forKey: "selectedTab")
            focusedDockTab = RootFocusReducer.dockTarget(for: selectedTab)
        }
        .task(id: model.account?.accountId) {
            if let account = model.account {
                if !BoundFolderStore.hasConfigured(accountID: account.accountId) {
                    showFolderSelection = true
                }
            }
        }
        .sheet(isPresented: $showFolderSelection) {
            if let client = model.client, let account = model.account {
                FolderSelectionScreen(client: client, accountID: account.accountId, diagnostics: model.diagnostics, isPresented: $showFolderSelection) {
                    selectedTab = .media
                }
            }
        }
    }

    // MARK: - Full-Width Dock Container (BUG FIX: Focus Section bridges entire screen width)
    private var dockContainer: some View {
        HStack {
            Spacer()
            floatingDockBar
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .focusSection()
        // Keep the dock in the focus tree and on-screen even while the library scrolls.
        // Hiding it made the next focus target disappear on tvOS and stranded the remote.
    }

    // MARK: - Floating Dock Bar Pill
    private var floatingDockBar: some View {
        HStack(spacing: 12) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                let isFocused = (focusedDockTab == tab)
                let isSelected = (selectedTab == tab)

                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon)
                        Text(tab.title)
                            .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .foregroundStyle(dockForeground(isFocused: isFocused, isSelected: isSelected))
                    .background(dockBackground(isFocused: isFocused, isSelected: isSelected), in: Capsule())
                    .overlay(
                        Capsule().stroke(dockStroke(isFocused: isFocused, isSelected: isSelected), lineWidth: isFocused ? 2.5 : 1)
                    )
                }
                .buttonStyle(.plain)
                .focused($focusedDockTab, equals: tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 12)
    }

    private func dockBackground(isFocused: Bool, isSelected: Bool) -> Color {
        if isFocused { return .white }
        if isSelected { return Color.cyan.opacity(0.35) }
        return .clear
    }

    private func dockForeground(isFocused: Bool, isSelected: Bool) -> Color {
        if isFocused { return .black }
        if isSelected { return .white }
        return Color.white.opacity(0.8)
    }

    private func dockStroke(isFocused: Bool, isSelected: Bool) -> Color {
        if isFocused { return .white }
        if isSelected { return Color.cyan.opacity(0.6) }
        return .clear
    }

    // MARK: - Cinema Tab
    @ViewBuilder
    private var cinemaTab: some View {
        if let account = model.account, let client = model.client,
           let mediaCatalog, let history {
            MediaLibraryScreen(
                client: client,
                accountID: account.accountId,
                history: history,
                tokenStore: TMDBCredentialStore(),
                catalog: mediaCatalog,
                diagnostics: model.diagnostics,
            )
            .id(account.accountId)
            .ignoresSafeArea(edges: .top)
        } else if model.account == nil {
            ScrollView {
                VStack(spacing: 32) {
                    HStack(spacing: 24) {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("THEATER").font(.system(size: 44, weight: .bold, design: .rounded))
                            Text("登录夸克网盘，开启电视私人影院").font(.headline).foregroundStyle(.secondary)
                        }
                    }
                    LoginScreen(model: model)
                }
                .frame(maxWidth: 1200)
                .padding(60)
            }
        } else {
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.6)
                Text("正在准备私人影院媒体库…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sources Tab
    @ViewBuilder
    private var sourcesTab: some View {
        if let account = model.account, let client = model.client {
            NavigationStack {
                SourcesManagementScreen(
                    model: model,
                    client: client,
                    accountID: account.accountId,
                    history: history,
                    showFolderSelection: $showFolderSelection,
                    onBackToCinema: { selectedTab = .media }
                )
            }
            .id(account.accountId)
            .padding(.top, 100)
        } else {
            VStack(spacing: 24) {
                Image(systemName: "folder.badge.person.crop").font(.system(size: 72))
                Text("登录后管理网盘").font(.title)
                Text("请前往影院使用夸克 App 扫码登录。").foregroundStyle(.secondary)
            }
            .padding(.top, 120)
        }
    }
}

private extension RootTab {
    var diagnosticFocusTarget: DiagnosticFocusTarget {
        switch self {
        case .media: return .media
        case .sources: return .sources
        case .settings: return .settings
        }
    }
}

private struct RootBackHandler: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

// MARK: - Sources Management Screen
@MainActor
private struct SourcesManagementScreen: View {
    let model: SessionViewModel
    let client: QuarkClient?
    let accountID: String
    let history: HistoryRepository?
    @Binding var showFolderSelection: Bool
    var onBackToCinema: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Button(action: onBackToCinema) {
                        Label("返回影院", systemImage: "arrow.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("网盘与存储源管理")
                        .font(.system(size: 42, weight: .bold))
                    Text("统一管理绑定的云盘与局域网存储。所有影视资源在【影院】大厅混排聚合呈现，无需手动切换源。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // Storage Source Cards Grid
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], spacing: 28) {
                    // Quark Drive
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "cloud.fill")
                                .font(.title)
                                .foregroundStyle(.cyan)
                            Text("夸克网盘")
                                .font(.title3.bold())
                            Spacer()
                            Text("已连接")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.2), in: Capsule())
                                .foregroundStyle(.green)
                        }

                        let count = BoundFolderStore.boundFolderIDs(accountID: accountID).count
                        Text(count > 0 ? "已绑定 \(count) 个影视文件夹并参与媒体库自动刮削" : "已连接 · 扫描根目录")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            Button {
                                showFolderSelection = true
                            } label: {
                                Label(count > 0 ? "管理绑定文件夹 (\(count))" : "选择绑定文件夹", systemImage: "folder.badge.gearshape")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.cyan)
                        }
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))

                    // Aliyun Drive
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "externaldrive.fill.badge.icloud")
                                .font(.title)
                                .foregroundStyle(.orange)
                            Text("阿里云盘")
                                .font(.title3.bold())
                            Spacer()
                            Text("即将推出")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Text("支持阿里云盘开放平台官方 OpenAPI 扫码授权，4K 原画高速串流。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("扫码授权 (规划中)") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))

                    // WebDAV
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "network")
                                .font(.title)
                                .foregroundStyle(.blue)
                            Text("WebDAV 协议")
                                .font(.title3.bold())
                            Spacer()
                            Text("即将推出")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Text("通用标准协议，可接入群晖/威联通/极空间 NAS、Alist 聚合挂载网盘。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("添加 WebDAV 节点 (规划中)") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))

                    // SMB
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.title)
                                .foregroundStyle(.mint)
                            Text("SMB 局域网共享")
                                .font(.title3.bold())
                            Spacer()
                            Text("即将推出")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Text("自动扫描局域网 Wi-Fi 内的 Mac/PC 与家庭服务器共享，局域网零外网流量秒播。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("局域网设备发现 (规划中)") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
                }
                .focusSection()

                // Cloud File Browser Section
                if let client {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("网盘文件目录浏览")
                            .font(.title2.bold())
                        FileBrowserScreen(client: client, diagnostics: model.diagnostics, isMock: model.isMock,
                                          accountID: accountID, history: history)
                    }
                    .padding(.top, 16)
                    .focusSection()
                }
            }
            .padding(60)
        }
        .focusSection()
    }
}

// MARK: - Settings Screen
@MainActor
private struct SettingsScreen: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    var onBackToCinema: () -> Void = {}
    @State private var tmdbToken = ""
    @State private var tmdbConfigured = false
    @State private var settingsMessage: String?
    @State private var showFolderSelection = false
    private let tmdbStore = TMDBCredentialStore()
    @State private var confirmLogout = false
    @State private var confirmClearHistory = false
    @State private var confirmClearMetadata = false
    @State private var diagnosticCategory: DiagnosticCategory?
    @State private var diagnosticsMessage: String?
    @State private var learnedAliases: [LearnedAlias] = []
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = true
    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"
    @AppStorage(PlayerSeekPreference.key) private var seekInterval = PlayerSeekPreference.defaultInterval
    @AppStorage("playbackEngine") private var playbackEngine = "ksplayer"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                // Top Exit / Back to Cinema Button (Guarantees upward navigation exit)
                HStack {
                    Button(action: onBackToCinema) {
                        Label("返回影院", systemImage: "arrow.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)

                    Spacer()
                }

                HStack(spacing: 24) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .shadow(color: Color(red: 0, green: 0.85, blue: 1.0).opacity(0.3), radius: 12, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("THEATER · 设置").font(.largeTitle.bold())
                        Text("版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0") · tvOS 原生私人影院")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Text("账号：\(model.account?.displayName ?? "未登录")")
                Text(model.isMock ? "运行模式：Mock（未连接真实服务）" : "运行模式：真实夸克接口 (v2/play 4K极速专线)")

                if let account = model.account {
                    Text("影视文件夹绑定").font(.title2.bold())
                    let count = BoundFolderStore.boundFolderIDs(accountID: account.accountId).count
                    Text("当前已绑定 \(count > 0 ? "\(count) 个文件夹" : "全盘扫描")。绑定文件夹后仅扫描影视目录，加快刮削速度。")
                        .foregroundStyle(.secondary)
                    Button {
                        showFolderSelection = true
                    } label: {
                        Label(count > 0 ? "管理绑定文件夹 (\(count) 个)" : "选择要绑定的文件夹", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                Text("TMDB 海报刮削设置").font(.title2.bold())
                Text("内置社区刮削源，支持同音字（蛛丝→蜘蛛侠）智能抗和谐映射与多层目录穿透。")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("刮削源语言首选项").font(.headline)
                    Picker("刮削源语言", selection: $scraperLanguage) {
                        Text("中文 (zh-CN) · 自动英文兜底").tag("zh-CN")
                        Text("English (en-US)").tag("en-US")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 800)
                }

                Text("自定义 TMDB Token（可选）").font(.headline)
                SecureField("自定义 TMDB API Read Access Token", text: $tmdbToken).frame(maxWidth: 900)
                HStack {
                    Button("保存自定义 Token") {
                        do {
                            try tmdbStore.save(tmdbToken)
                            tmdbToken = ""
                            tmdbConfigured = true
                            settingsMessage = "自定义 TMDB Token 已安全保存。"
                        } catch {
                            settingsMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if tmdbConfigured {
                        Button("清除自定义 Token", role: .destructive) {
                            try? tmdbStore.delete()
                            tmdbConfigured = false
                            settingsMessage = "已恢复为内置开箱即用 TMDB Key。"
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("播放偏好").font(.title2.bold())
                VStack(alignment: .leading, spacing: 8) {
                    Text("解码播放引擎").font(.headline)
                    Picker("播放引擎", selection: $playbackEngine) {
                        Text("KSPlayer (FFmpeg 强解 · 突破防盗链 / MKV / 多音轨)").tag("ksplayer")
                        Text("系统原生 (AVPlayer)").tag("avplayer")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 950)
                }

                Toggle("剧集自动连播下一集", isOn: $autoPlayNextEpisode)
                    .frame(maxWidth: 800)
                Picker("跳过时长", selection: $seekInterval) {
                    Text("10 秒").tag(10)
                    Text("15 秒").tag(15)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 800)
                .onChange(of: seekInterval) { _, value in
                    if value != 10 && value != 15 { seekInterval = PlayerSeekPreference.defaultInterval }
                }

                Text("已学习别名").font(.title2.bold())
                if learnedAliases.isEmpty {
                    Text("暂无已确认别名。手动确认匹配后会显示在这里。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(learnedAliases) { alias in
                        HStack {
                            Text("\(alias.sourceTitle) → \(alias.canonicalTitle)")
                            Spacer()
                            Text(alias.mediaType.rawValue).foregroundStyle(.secondary)
                            Button("删除", role: .destructive) { removeAlias(alias) }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Text("数据维护与缓存管理").font(.title2.bold())
                HStack(spacing: 20) {
                    Button("清理全部观看记录", role: .destructive) { confirmClearHistory = true }
                        .buttonStyle(.bordered)

                    Button("清空影视匹配缓存并重新刮削", role: .destructive) { confirmClearMetadata = true }
                        .buttonStyle(.bordered)

                    Button("退出当前账号", role: .destructive) { confirmLogout = true }
                        .buttonStyle(.bordered)
                }

                if let settingsMessage {
                    Text(settingsMessage).foregroundStyle(.cyan).font(.callout)
                }

                // Integrated Diagnostics Section
                Text("诊断与日志记录").font(.title2.bold())
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近运行事件（不记录 Cookie 与令牌）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("分类", selection: $diagnosticCategory) {
                            Text("全部").tag(DiagnosticCategory?.none)
                            ForEach(DiagnosticCategory.allCases, id: \.self) { category in
                                Text(category.rawValue).tag(Optional(category))
                            }
                        }
                        .pickerStyle(.menu)
                        Button("导出") { exportDiagnostics() }
                            .buttonStyle(.bordered)
                        Button("清空日志") {
                            diagnosticsMessage = nil
                            Task {
                                switch await model.diagnostics.clear().value {
                                case .success:
                                    diagnosticsMessage = "日志已清空。"
                                case .failure(let failure):
                                    diagnosticsMessage = "清空日志失败（\(failure.operation.rawValue)，错误码 \(failure.code)）"
                                }
                            }
                        }
                            .buttonStyle(.bordered)
                    }
                    if visibleDiagnosticRecords.isEmpty {
                        Text("暂无符合当前筛选条件的诊断记录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(visibleDiagnosticRecords) { record in
                            HStack(alignment: .top, spacing: 16) {
                                Text(record.date, style: .time).monospacedDigit().font(.caption2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("[\(record.category.rawValue)] \(record.event.rawValue)").font(.caption.bold())
                                    Text(diagnosticSummary(record)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if let failure = model.diagnostics.storageFailure {
                        Text("日志存储失败（\(failure.operation.rawValue)，错误码 \(failure.code)）")
                            .foregroundStyle(.orange)
                    }
                    if let diagnosticsMessage { Text(diagnosticsMessage).foregroundStyle(.cyan) }
                }
                .padding(20)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: 1500, alignment: .leading)
            .padding(60)
        }
        .confirmationDialog("退出当前夸克账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                onBackToCinema()
                Task { await model.logout() }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清理当前账号的全部观看记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清理观看记录", role: .destructive) {
                guard let accountID = model.account?.accountId else { return }
                do { try history?.clear(accountID: accountID); settingsMessage = "观看记录已清理。" }
                catch { settingsMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空当前账号全部影视匹配？", isPresented: $confirmClearMetadata, titleVisibility: .visible) {
            Button("清空并重置媒体库", role: .destructive) {
                guard let accountID = model.account?.accountId else { return }
                do { try mediaCatalog?.clearAll(accountID: accountID); settingsMessage = "影视匹配缓存已全部清空，请前往【影院】重新扫描。" }
                catch { settingsMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showFolderSelection) {
            if let client = model.client, let account = model.account {
                FolderSelectionScreen(client: client, accountID: account.accountId, diagnostics: model.diagnostics, isPresented: $showFolderSelection) {}
            }
        }
        .task {
            tmdbConfigured = (try? tmdbStore.load()) != nil
            if seekInterval != 10 && seekInterval != 15 { seekInterval = PlayerSeekPreference.defaultInterval }
            reloadAliases()
        }
    }

    private func diagnosticSummary(_ record: DiagnosticRecord) -> String {
        record.metadata.keys.sorted().compactMap { key in
            guard let value = record.metadata[key] else { return nil }
            return "\(key)=\(String(describing: value))"
        }.joined(separator: " · ")
    }

    private var visibleDiagnosticRecords: [DiagnosticRecord] {
        DiagnosticRecordProjection.visible(model.diagnostics.records, category: diagnosticCategory)
    }

    private func exportDiagnostics() {
        Task {
            switch await model.diagnostics.export() {
            case .success(let url): diagnosticsMessage = "已导出：\(url.lastPathComponent)（\(url.deletingLastPathComponent().path)）"
            case .failure(let failure): diagnosticsMessage = "导出失败（错误码 \(failure.code)）"
            }
        }
    }

    private func reloadAliases() {
        guard let accountID = model.account?.accountId, let mediaCatalog else { learnedAliases = []; return }
        learnedAliases = (try? mediaCatalog.learnedAliases(accountID: accountID)) ?? []
    }

    private func removeAlias(_ alias: LearnedAlias) {
        guard let mediaCatalog else { return }
        do {
            try mediaCatalog.removeLearnedAlias(accountID: alias.accountID, mediaType: alias.mediaType, sourceTitle: alias.sourceTitle)
            reloadAliases()
            settingsMessage = "已删除别名，媒体库条目未删除。"
        } catch { settingsMessage = "删除别名失败：\(error.localizedDescription)" }
    }
}
