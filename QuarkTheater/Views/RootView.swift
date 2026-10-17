import SwiftUI

@MainActor
struct RootView: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("QUARK THEATER").font(.system(size: 60, weight: .bold, design: .rounded))
                    Text("你的网盘，电视上的私人影院").font(.title2).foregroundStyle(.secondary)
                    if model.isMock {
                        Label("MOCK · 模拟数据 · 未连接夸克", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    if let account = model.account {
                        Label(account.displayName, systemImage: "person.crop.circle.badge.checkmark").font(.title2)
                        Text("已登录。使用顶部“网盘”浏览文件，或在“媒体库”扫描影片。")
                        Text("打开媒体库扫描影片，或在历史页继续观看上次进度。").foregroundStyle(.secondary)
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
            .tabItem { Label("首页", systemImage: "house") }

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
            }.tabItem { Label("网盘", systemImage: "folder") }
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
            }.tabItem { Label("媒体库", systemImage: "rectangle.stack") }
            Group {
                if let account = model.account, let history, let client = model.client {
                    HistoryScreen(repository: history, accountID: account.accountId, client: client,
                                  diagnostics: model.diagnostics).id(account.accountId)
                } else {
                    VStack(spacing: 20) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 60)); Text("登录后查看观看历史") }
                }
            }.tabItem { Label("历史", systemImage: "clock") }
            SettingsScreen(model: model, history: history, mediaCatalog: mediaCatalog).tabItem { Label("设置", systemImage: "gearshape") }
            DiagnosticsScreen(diagnostics: model.diagnostics).tabItem { Label("诊断", systemImage: "waveform.path.ecg") }
        }.tint(.cyan)
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
    private let tmdbStore = TMDBCredentialStore()
    @State private var confirmLogout = false
    @State private var confirmClearHistory = false
    @State private var confirmClearMetadata = false
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("设置").font(.largeTitle.bold())
                Text("账号：\(model.account?.displayName ?? "未登录")")
                Text(model.isMock ? "运行模式：Mock（未连接真实服务）" : "运行模式：真实夸克接口")
                Text("版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") · 第一轮")
                    .foregroundStyle(.secondary)
                Text("TMDB 元数据").font(.title2.bold())
                SecureField("TMDB API Read Access Token", text: $tmdbToken).frame(maxWidth: 900)
                HStack {
                    Button("保存到 Keychain") {
                        do { try tmdbStore.save(tmdbToken); tmdbToken = ""; tmdbConfigured = true; settingsMessage = "TMDB Token 已安全保存。" }
                        catch { settingsMessage = error.localizedDescription }
                    }.disabled(tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("清除 Token", role: .destructive) {
                        do { try tmdbStore.delete(); tmdbToken = ""; tmdbConfigured = false; settingsMessage = "已清除 TMDB Token。" }
                        catch { settingsMessage = error.localizedDescription }
                    }.disabled(!tmdbConfigured)
                }
                Text(tmdbConfigured ? "TMDB 已配置" : "TMDB 尚未配置").foregroundStyle(.secondary)
                Toggle("电视剧自动播放下一集", isOn: $autoPlayNextEpisode).frame(maxWidth: 900)
                if let settingsMessage { Text(settingsMessage).foregroundStyle(.secondary) }
                if model.account != nil {
                    Button("退出登录", role: .destructive) { confirmLogout = true }.disabled(model.isBusy)
                    Button("清理观看记录", role: .destructive) { confirmClearHistory = true }
                    Button("清理已确认影视元数据", role: .destructive) { confirmClearMetadata = true }
                }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
                Text("TMDB Token 保存在 Keychain；媒体扫描结果和观看进度仅保存在本机。").foregroundStyle(.secondary)
            }.frame(maxWidth: 1400, alignment: .leading).padding(60)
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
