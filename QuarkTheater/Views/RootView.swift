import SwiftUI

private enum RootTab: String, Hashable, CaseIterable {
    case home, files, media, history, settings, diagnostics
}

@MainActor
struct RootView: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    @AppStorage("selectedTab") private var selectedTab: RootTab = .home
    @State private var showFolderSelection = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        HStack(spacing: 28) {
                            Image("AppLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 88, height: 88)
                                .shadow(color: Color(red: 0, green: 0.85, blue: 1.0).opacity(0.4), radius: 16, x: 0, y: 6)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("QUARK THEATER").font(.system(size: 56, weight: .bold, design: .rounded))
                                Text("你的网盘，电视上的私人影院").font(.title3).foregroundStyle(.secondary)
                            }
                        }
                        if model.isMock {
                            Label("MOCK · 模拟数据 · 未连接夸克", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        }
                        if let account = model.account {
                            Label(account.displayName, systemImage: "person.crop.circle.badge.checkmark").font(.title2)
                            Text("已登录。使用顶部“网盘”浏览文件，或在“媒体库”扫描影片。")
                            Text("打开媒体库扫描影片，或在历史页继续观看上次进度。").foregroundStyle(.secondary)

                            HStack(spacing: 24) {
                                Button {
                                    selectedTab = .files
                                } label: {
                                    Label("进入我的网盘", systemImage: "folder.fill")
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    selectedTab = .media
                                } label: {
                                    Label("媒体库", systemImage: "rectangle.stack.fill")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    showFolderSelection = true
                                } label: {
                                    let count = BoundFolderStore.boundFolderIDs(accountID: account.accountId).count
                                    Label(count > 0 ? "已绑定 \(count) 个文件夹" : "选择绑定文件夹", systemImage: "folder.badge.gearshape")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    selectedTab = .diagnostics
                                } label: {
                                    Label("系统诊断", systemImage: "waveform.path.ecg")
                                }
                                .buttonStyle(.bordered)

                                Button(role: .destructive) {
                                    Task { await model.logout() }
                                } label: {
                                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                                .buttonStyle(.bordered)
                            }
                            .navigationDestination(for: String.self) { destination in
                                if destination == "files", let client = model.client {
                                    FileBrowserScreen(client: client, diagnostics: model.diagnostics, isMock: model.isMock,
                                                      accountID: account.accountId, history: history)
                                } else if destination == "media", let client = model.client, let mediaCatalog, let history {
                                    MediaLibraryScreen(client: client, accountID: account.accountId,
                                                       history: history, tokenStore: TMDBCredentialStore(),
                                                       catalog: mediaCatalog, diagnostics: model.diagnostics)
                                } else if destination == "diagnostics" {
                                    DiagnosticsScreen(diagnostics: model.diagnostics)
                                }
                            }

                            if let client = model.client, let history {
                                HomeContinueWatchingView(repository: history, accountID: account.accountId,
                                    client: client, diagnostics: model.diagnostics)
                            }
                        } else {
                            LoginScreen(model: model)
                        }
                    }.frame(maxWidth: 1500, alignment: .leading).padding(60)
                }
                .background(LinearGradient(colors: [Color(red: 0.035, green: 0.08, blue: 0.13), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .tabItem { Label("首页", systemImage: "house") }
            .tag(RootTab.home)

            Group {
                if let account = model.account, let client = model.client {
                    NavigationStack {
                        FileBrowserScreen(client: client, diagnostics: model.diagnostics, isMock: model.isMock,
                                          accountID: account.accountId, history: history)
                    }.id(account.accountId)
                } else {
                    VStack(spacing: 24) {
                        Image(systemName: "folder.badge.person.crop").font(.system(size: 72))
                        Text("登录后浏览网盘").font(.title)
                        Text("请前往首页，使用夸克 App 扫码登录。").foregroundStyle(.secondary)
                    }
                }
            }
            .tabItem { Label("网盘", systemImage: "folder") }
            .tag(RootTab.files)

            Group {
                if let account = model.account, let client = model.client,
                   let mediaCatalog, let history {
                    MediaLibraryScreen(client: client, accountID: account.accountId,
                        history: history, tokenStore: TMDBCredentialStore(),
                        catalog: mediaCatalog, diagnostics: model.diagnostics)
                        .id(account.accountId)
                } else {
                    VStack(spacing: 20) { Image(systemName: "film.stack").font(.system(size: 60)); Text("登录后扫描媒体库") }
                }
            }
            .tabItem { Label("媒体库", systemImage: "rectangle.stack") }
            .tag(RootTab.media)

            Group {
                if let account = model.account, let history, let client = model.client {
                    HistoryScreen(repository: history, accountID: account.accountId, client: client,
                                  diagnostics: model.diagnostics).id(account.accountId)
                } else {
                    VStack(spacing: 20) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 60)); Text("登录后查看观看历史") }
                }
            }
            .tabItem { Label("历史", systemImage: "clock") }
            .tag(RootTab.history)

            SettingsScreen(model: model, history: history, mediaCatalog: mediaCatalog)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(RootTab.settings)

            DiagnosticsScreen(diagnostics: model.diagnostics)
                .tabItem { Label("诊断", systemImage: "waveform.path.ecg") }
                .tag(RootTab.diagnostics)
        }
        .tint(.cyan)
        .task(id: model.account?.accountId) {
            if let account = model.account, !BoundFolderStore.hasConfigured(accountID: account.accountId) {
                showFolderSelection = true
            }
        }
        .sheet(isPresented: $showFolderSelection) {
            if let client = model.client, let account = model.account {
                FolderSelectionScreen(client: client, accountID: account.accountId, diagnostics: model.diagnostics, isPresented: $showFolderSelection) {}
            }
        }
    }
}

@MainActor
private struct SettingsScreen: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    @State private var tmdbToken = ""
    @State private var tmdbConfigured = false
    @State private var settingsMessage: String?
    @State private var showFolderSelection = false
    private let tmdbStore = TMDBCredentialStore()
    @State private var confirmLogout = false
    @State private var confirmClearHistory = false
    @State private var confirmClearMetadata = false
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = false
    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 24) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .shadow(color: Color(red: 0, green: 0.85, blue: 1.0).opacity(0.3), radius: 12, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("QUARK THEATER · 设置").font(.largeTitle.bold())
                        Text("版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") · tvOS 原生私人影院")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text("账号：\(model.account?.displayName ?? "未登录")")
                Text(model.isMock ? "运行模式：Mock（未连接真实服务）" : "运行模式：真实夸克接口")

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

                Text("TMDB 海报刮削（开箱即用）").font(.title2.bold())
                Text("内置开箱即用社区刮削 Key，无需任何额外配置即可自动获取电影、电视剧封面海报与剧集信息。")
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
                    }.disabled(tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("恢复内置 Key", role: .destructive) {
                        do {
                            try tmdbStore.delete()
                            tmdbToken = ""
                            tmdbConfigured = false
                            settingsMessage = "已清除自定义 Token，已恢复使用内置 Key。"
                        } catch {
                            settingsMessage = error.localizedDescription
                        }
                    }.disabled(!tmdbConfigured)
                }
                Text(tmdbConfigured ? "当前使用：用户自定义 TMDB Token" : "当前使用：内置开箱即用社区 Key").foregroundStyle(.secondary)

                Toggle("电视剧自动播放下一集", isOn: $autoPlayNextEpisode).frame(maxWidth: 900)
                if let settingsMessage { Text(settingsMessage).foregroundStyle(.secondary) }
                if model.account != nil {
                    Button("退出登录", role: .destructive) { confirmLogout = true }.disabled(model.isBusy)
                    Button("清理观看记录", role: .destructive) { confirmClearHistory = true }
                    Button("清理已确认影视元数据", role: .destructive) { confirmClearMetadata = true }
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }.frame(maxWidth: 1400, alignment: .leading).padding(60)
        }
        .sheet(isPresented: $showFolderSelection) {
            if let client = model.client, let account = model.account {
                FolderSelectionScreen(client: client, accountID: account.accountId, diagnostics: model.diagnostics, isPresented: $showFolderSelection) {}
            }
        }
        .confirmationDialog("退出当前夸克账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await model.logout() } }
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
        .confirmationDialog("清理当前账号已确认的影视匹配？", isPresented: $confirmClearMetadata, titleVisibility: .visible) {
            Button("清理元数据", role: .destructive) {
                guard let accountID = model.account?.accountId else { return }
                do { try mediaCatalog?.clear(accountID: accountID); settingsMessage = "影视匹配缓存已清理。" }
                catch { settingsMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
        .task { tmdbConfigured = (try? tmdbStore.load()) != nil }
    }
}

@MainActor
private struct DiagnosticsScreen: View {
    @ObservedObject var diagnostics: Diagnostics
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("诊断记录").font(.largeTitle.bold())
                    Spacer()
                    Button("清空") { diagnostics.clear() }
                }
                Text("仅保留本次运行最近 100 条事件；不记录 Cookie、二维码令牌或下载地址。").foregroundStyle(.secondary)
                if diagnostics.entries.isEmpty { Text("暂无记录") }
                ForEach(diagnostics.entries) { entry in
                    HStack(alignment: .top, spacing: 24) {
                        Text(entry.date, style: .time).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
            }.frame(maxWidth: 1500, alignment: .leading).padding(60)
        }
    }
}
