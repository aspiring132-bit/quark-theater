import SwiftUI

@MainActor
struct SettingsHomeScreen: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    var onBackToCinema: () -> Void = {}
    var onNavigateToSources: () -> Void = {}

    @State private var selectedCategory: SettingsCategory? = nil
    @FocusState private var focusedCategory: SettingsCategory?

    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = true
    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"
    @AppStorage(PlayerSeekPreference.key) private var seekInterval = PlayerSeekPreference.defaultInterval

    var body: some View {
        Group {
            if let category = selectedCategory {
                categoryDetailView(for: category)
            } else {
                homeMenuView
            }
        }
    }

    // MARK: - Home Category Menu View
    private var homeMenuView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Top Exit / Back to Cinema Button
                HStack {
                    Button(action: onBackToCinema) {
                        Label("返回影院", systemImage: "arrow.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.glassWhite)

                    Spacer()
                }

                // Header Banner
                HStack(spacing: 24) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .shadow(color: BrandPalette.iceGlow.opacity(0.55), radius: 12, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("THEATER · 设置").font(.largeTitle.bold())
                        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
                        Text("版本：V\(appVersion.replacingOccurrences(of: ".", with: "-")) · tvOS 原生私人影院")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                // Categories List (Full-Width Focusable Rows)
                VStack(spacing: 16) {
                    ForEach(SettingsCategory.allCases) { category in
                        categoryCard(for: category)
                    }
                }
                .focusSection()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
        }
        .focusSection()
        .onExitCommand(perform: onBackToCinema)
    }

    // MARK: - Category Row Button
    private func categoryCard(for category: SettingsCategory) -> some View {
        let isFocused = (focusedCategory == category)

        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 24) {
                Image(systemName: category.icon)
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(isFocused ? Color.black : BrandPalette.iceBlue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title)
                        .font(.title3.bold())
                        .foregroundStyle(isFocused ? Color.black : BrandPalette.glassWhite)

                    Text(category.subtitle)
                        .font(.callout)
                        .foregroundStyle(isFocused ? Color.black.opacity(0.7) : BrandPalette.secondaryText)
                }

                Spacer()

                if let badge = statusBadge(for: category) {
                    Text(badge)
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(isFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(isFocused ? Color.black : BrandPalette.glassWhite.opacity(0.85))
                }

                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(isFocused ? Color.black : BrandPalette.secondaryText)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background(isFocused ? Color.white : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? Color.white : Color.white.opacity(0.12), lineWidth: isFocused ? 2.5 : 1)
            )
            .scaleEffect(isFocused ? 1.02 : 1.0)
            .shadow(color: isFocused ? Color.black.opacity(0.35) : .clear, radius: 12, x: 0, y: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focusedCategory, equals: category)
    }

    private func statusBadge(for category: SettingsCategory) -> String? {
        switch category {
        case .sources:
            if let account = model.account {
                let bound = BoundFolderStore.boundFolderIDs(accountID: account.accountId).count
                return "已连接 (\(bound) 文件夹)"
            }
            return "未连接"
        case .playback:
            let seek = PlayerSeekMath.normalizedInterval(seekInterval)
            return "\(autoPlayNextEpisode ? "连播开" : "连播关") · \(seek)s"
        case .scraper:
            return scraperLanguage == "zh-CN" ? "中文" : "English"
        case .dataCache:
            return "本地维护"
        case .diagnostics:
            let count = model.diagnostics.records.count
            return "\(count) 条记录"
        case .about:
            return "Mujio"
        }
    }

    // MARK: - Detail View Router
    @ViewBuilder
    private func categoryDetailView(for category: SettingsCategory) -> some View {
        let dismissAction = {
            let restoreTarget = SettingsFocusReducer.restoredFocusTarget(afterExiting: category)
            selectedCategory = SettingsFocusReducer.categoryAfterBack(selectedCategory: category)
            focusedCategory = restoreTarget
        }

        switch category {
        case .sources:
            MediaSourcesSettingsScreen(
                model: model,
                onBack: dismissAction,
                onNavigateToSources: {
                    dismissAction()
                    onNavigateToSources()
                }
            )
        case .playback:
            PlaybackSettingsScreen(onBack: dismissAction)
        case .scraper:
            ScraperSettingsScreen(model: model, mediaCatalog: mediaCatalog, onBack: dismissAction)
        case .dataCache:
            DataCacheSettingsScreen(
                model: model,
                history: history,
                mediaCatalog: mediaCatalog,
                onBack: dismissAction,
                onLoggedOut: {
                    dismissAction()
                    onBackToCinema()
                }
            )
        case .diagnostics:
            DiagnosticsSettingsScreen(model: model, onBack: dismissAction)
        case .about:
            AboutSettingsScreen(onBack: dismissAction)
        }
    }
}
