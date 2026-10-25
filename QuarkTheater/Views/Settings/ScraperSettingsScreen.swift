import SwiftUI

@MainActor
struct ScraperSettingsScreen: View {
    @ObservedObject var model: SessionViewModel
    let mediaCatalog: MediaCatalogRepository?
    var onBack: () -> Void = {}

    @AppStorage("scraperLanguage") private var scraperLanguage = "zh-CN"
    @State private var tmdbToken = ""
    @State private var tmdbConfigured = false
    @State private var message: String?
    @State private var learnedAliases: [LearnedAlias] = []
    private let tmdbStore = TMDBCredentialStore()

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
                    Text("刮削与匹配")
                        .font(.system(size: 38, weight: .bold))
                    Text("管理 TMDB 海报刮削语言、API 凭据以及手动确认的影视别名映射。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                // TMDB Settings
                VStack(alignment: .leading, spacing: 20) {
                    Text("TMDB 元数据设置").font(.title3.bold())

                    VStack(alignment: .leading, spacing: 8) {
                        Text("刮削语言首选项").font(.headline)
                        Picker("刮削源语言", selection: $scraperLanguage) {
                            Text("中文 (zh-CN) · 自动英文兜底").tag("zh-CN")
                            Text("English (en-US)").tag("en-US")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 800)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义 TMDB Read Access Token (可选)").font(.headline)
                        Text("若不填写，默认使用内置开箱即用的 TMDB 凭据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("自定义 TMDB API Read Access Token", text: $tmdbToken)
                            .frame(maxWidth: 900)

                        HStack(spacing: 16) {
                            Button("保存自定义 Token") {
                                do {
                                    try tmdbStore.save(tmdbToken)
                                    tmdbToken = ""
                                    tmdbConfigured = true
                                    message = "自定义 TMDB Token 已安全存入 Keychain。"
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(BrandPalette.glassWhite)

                            if tmdbConfigured {
                                Button("清除自定义 Token", role: .destructive) {
                                    try? tmdbStore.delete()
                                    tmdbConfigured = false
                                    message = "已恢复为内置开箱即用 TMDB 凭据。"
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .padding(28)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                .focusSection()

                // Learned Aliases
                VStack(alignment: .leading, spacing: 16) {
                    Text("已学习影视别名").font(.title3.bold())
                    Text("当手动调整匹配时，系统会记录对应规则以便下次自动命中。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if learnedAliases.isEmpty {
                        Text("暂无已确认别名。手动确认匹配后会显示在这里。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(learnedAliases) { alias in
                            HStack {
                                Text("\(alias.sourceTitle) → \(alias.canonicalTitle)")
                                    .font(.callout)
                                Spacer()
                                Text(alias.mediaType.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("删除", role: .destructive) {
                                    removeAlias(alias)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
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
        .task {
            tmdbConfigured = (try? tmdbStore.load()) != nil
            reloadAliases()
        }
    }

    private func reloadAliases() {
        guard let accountID = model.account?.accountId, let mediaCatalog else {
            learnedAliases = []
            return
        }
        learnedAliases = (try? mediaCatalog.learnedAliases(accountID: accountID)) ?? []
    }

    private func removeAlias(_ alias: LearnedAlias) {
        guard let mediaCatalog else { return }
        do {
            try mediaCatalog.removeLearnedAlias(accountID: alias.accountID, mediaType: alias.mediaType, sourceTitle: alias.sourceTitle)
            reloadAliases()
            message = "已删除别名规则，媒体库已有影视条目保持不变。"
        } catch {
            message = "删除别名失败：\(error.localizedDescription)"
        }
    }
}
