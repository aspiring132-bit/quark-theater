import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    /// 本地数据库启动报告（2026-10-18 真机卡死修复：失败可见、可恢复）
    var storageBoot: StorageBootReport = StorageBootReport()
    var onRetryStorage: () -> Void = {}
    var onResetStorage: () -> Void = {}
    @State private var selectedTab: RootTab = .media
    @State private var showFolderSelection = false
    @State private var didRecordStorageFailure = false
    @FocusState private var focusedDockTab: RootTab?

    var body: some View {
        ZStack(alignment: .top) {
            BrandPalette.deepCharcoal
                .ignoresSafeArea()

            // If not logged in, ALWAYS show cinemaTab (which renders LoginScreen)
            if model.account == nil {
                cinemaTab
            } else {
                ZStack(alignment: .top) {
                    // MARK: - 1. Screen Contents (Extends completely to Y=0 top edge)
                    Group {
                        switch selectedTab {
                        case .media:
                            cinemaTab
                        case .sources:
                            sourcesTab
                        case .settings:
                            SettingsHomeScreen(
                                model: model,
                                history: history,
                                mediaCatalog: mediaCatalog,
                                onBackToCinema: { selectedTab = .media },
                                onNavigateToSources: { selectedTab = .sources }
                            )
                            // Handover task 1a: widen the gap below the floating dock so it
                            // never overlaps Settings content on smaller/odd-ratio screens.
                            .padding(.top, 140)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // MARK: - 2. Full-Width FocusSection Floating Dock Bar
                    dockContainer
                }
                .blur(radius: FolderBindingBackdropStyle.blur(isPresented: showFolderSelection))
                .overlay {
                    if showFolderSelection {
                        Color.black.opacity(FolderBindingBackdropStyle.dimming(isPresented: true))
                            .ignoresSafeArea()
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showFolderSelection)
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
        HStack(spacing: 24) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                let isFocused = (focusedDockTab == tab)
                let isSelected = (selectedTab == tab)

                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                        Text(tab.title)
                            .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .foregroundStyle(dockForeground(isFocused: isFocused, isSelected: isSelected))
                    .background(dockBackground(isFocused: isFocused, isSelected: isSelected), in: Capsule())
                    .overlay(
                        Capsule().stroke(dockStroke(isFocused: isFocused, isSelected: isSelected), lineWidth: isFocused ? 2.5 : 1)
                    )
                    .scaleEffect(isFocused ? 1.05 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isFocused)
                }
                .buttonStyle(.plain)
                .focused($focusedDockTab, equals: tab)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 24, x: 0, y: 12)
    }

    private func dockBackground(isFocused: Bool, isSelected: Bool) -> Color {
        if isFocused { return .white }
        if isSelected { return BrandPalette.glassWhite.opacity(0.12) }
        return .clear
    }

    private func dockForeground(isFocused: Bool, isSelected: Bool) -> Color {
        if isFocused { return .black }
        if isSelected { return .white }
        return Color.white.opacity(0.8)
    }

    private func dockStroke(isFocused: Bool, isSelected: Bool) -> Color {
        if isFocused { return .white }
        if isSelected { return BrandPalette.iceBlue.opacity(0.22) }
        return .clear
    }

    // MARK: - Cinema Tab
    @ViewBuilder
    private var cinemaTab: some View {
        if let account = model.account, let client = model.client,
           let mediaCatalog, let history {
            ZStack(alignment: .top) {
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

                // 降级模式横幅：主库失败但已回退临时库，首页可用但数据不持久化
                if storageBoot.isDegraded {
                    storageDegradedBanner
                }
            }
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
        } else if storageBoot.hasFailure {
            // 本地数据库初始化彻底失败（无降级库可用）：显示原因与恢复入口，
            // 不再让用户永远停在"正在准备…"转圈页（2026-10-18 真机卡死修复）
            storageFailurePanel
        } else {
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.6)
                Text("正在准备私人影院媒体库…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 本地数据库失败恢复面板
    private var storageFailurePanel: some View {
        VStack(spacing: 24) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("本地媒体数据库初始化失败")
                .font(.title.bold())
            Text(storageBoot.summary.isEmpty ? "未知原因。" : storageBoot.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1000)
            Text("可先重试初始化；若仍失败，清除本地缓存后将重建空数据库（观看记录与已刮削匹配会清空，网盘文件不受影响）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            HStack(spacing: 20) {
                Button("重试初始化", action: onRetryStorage)
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.glassWhite)
                Button("清除本地缓存并重建", role: .destructive, action: onResetStorage)
                    .buttonStyle(.bordered)
            }
        }
        .padding(60)
        .focusSection()
        .task {
            guard !didRecordStorageFailure else { return }
            didRecordStorageFailure = true
            model.diagnostics.record("本地数据库初始化失败，已展示恢复面板。")
        }
    }

    // MARK: - 降级模式横幅（首页顶部悬浮）
    private var storageDegradedBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("本地数据库异常，已切换为临时降级模式（观看记录与刮削缓存本次不保存）。")
                    .font(.callout)
                if !storageBoot.summary.isEmpty {
                    Text(storageBoot.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Button("重试初始化", action: onRetryStorage)
                .buttonStyle(.bordered)
            Button("清除并重建", role: .destructive, action: onResetStorage)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        .padding(.top, 130)
        .focusSection()
        .task {
            guard !didRecordStorageFailure else { return }
            didRecordStorageFailure = true
            model.diagnostics.record("本地数据库初始化失败，已启用临时降级模式。")
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
                    mediaCatalog: mediaCatalog,
                    onBackToCinema: { selectedTab = .media }
                )
            }
            .id(account.accountId)
            .padding(.top, 140)
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
