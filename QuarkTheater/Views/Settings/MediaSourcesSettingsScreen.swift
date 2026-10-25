import SwiftUI

@MainActor
struct MediaSourcesSettingsScreen: View {
    @ObservedObject var model: SessionViewModel
    var onBack: () -> Void = {}
    var onNavigateToSources: () -> Void = {}

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
                    Text("媒体来源摘要")
                        .font(.system(size: 38, weight: .bold))
                    Text("所有已挂载网盘与本地存储的影视资源均在【影院】混排呈现。若需添加新来源、解绑或修改目录，请前往【网盘管理】。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        Image(systemName: "cloud.fill")
                            .font(.title)
                            .foregroundStyle(BrandPalette.iceBlue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("夸克网盘")
                                .font(.title3.bold())
                            if let account = model.account {
                                let boundCount = BoundFolderStore.boundFolderIDs(accountID: account.accountId).count
                                Text("当前账号：\(account.displayName) · 已绑定 \(boundCount) 个文件夹")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("未登录")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(model.account != nil ? "已连接" : "未连接")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(model.account != nil ? Color.green.opacity(0.2) : Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(model.account != nil ? Color.green : Color.secondary)
                    }
                    .padding(24)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                    Button(action: onNavigateToSources) {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.connected.to.line.below")
                            Text("前往网盘管理大厅")
                                .font(.headline.bold())
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandPalette.glassWhite)
                }
                .focusSection()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
        }
        .onExitCommand(perform: onBack)
    }
}
