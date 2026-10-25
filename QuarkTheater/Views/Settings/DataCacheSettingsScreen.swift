import SwiftUI

@MainActor
struct DataCacheSettingsScreen: View {
    @ObservedObject var model: SessionViewModel
    let history: HistoryRepository?
    let mediaCatalog: MediaCatalogRepository?
    var onBack: () -> Void = {}
    var onLoggedOut: () -> Void = {}

    @State private var confirmClearHistory = false
    @State private var confirmClearMetadata = false
    @State private var confirmLogout = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack {
                    Button(action: onBack) {
                        Label("返回设置", systemImage: "arrow.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("数据与缓存")
                        .font(.system(size: 38, weight: .bold))
                    Text("本地缓存维护与账号会话管理。以下操作仅影响 Apple TV 本机数据，绝不修改或删除网盘与 NAS 上的原始文件。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("观看记录维护").font(.title3.bold())
                        Text("清除当前账号在电视端记录的全部播放进度与已看标记。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("清理全部观看记录", role: .destructive) {
                            confirmClearHistory = true
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider().background(Color.white.opacity(0.1))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("影视匹配缓存维护").font(.title3.bold())
                        Text("清空本地 TMDB 匹配条目与海报缓存，触发下次进入影院时重新全盘刮削。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("清空影视匹配缓存并重新刮削", role: .destructive) {
                            confirmClearMetadata = true
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider().background(Color.white.opacity(0.1))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前账号会话").font(.title3.bold())
                        Text("退出当前账号将清除本地登录凭据，需重新扫码授权登录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("退出当前夸克账号", role: .destructive) {
                            confirmLogout = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(28)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                .focusSection()

                if let message {
                    Text(message).foregroundStyle(BrandPalette.glassWhite).font(.callout)
                }
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
        }
        .onExitCommand(perform: onBack)
        .confirmationDialog("清理当前账号全部观看记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("确认清理", role: .destructive) {
                guard let accountID = model.account?.accountId else { return }
                do {
                    try history?.clear(accountID: accountID)
                    message = "观看记录已清空。"
                } catch {
                    message = "清理失败：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空当前账号全部影视匹配？", isPresented: $confirmClearMetadata, titleVisibility: .visible) {
            Button("确认清空并重置", role: .destructive) {
                guard let accountID = model.account?.accountId else { return }
                do {
                    try mediaCatalog?.clearAll(accountID: accountID)
                    message = "影视匹配缓存已全部清空，请前往【影院】重新扫描。"
                } catch {
                    message = "清空失败：\(error.localizedDescription)"
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出当前夸克账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("确认退出登录", role: .destructive) {
                onLoggedOut()
                Task {
                    await model.logout()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}
