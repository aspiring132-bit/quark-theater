import SwiftUI

@MainActor
struct AboutSettingsScreen: View {
    var onBack: () -> Void = {}

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

                HStack(spacing: 24) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .shadow(color: BrandPalette.iceGlow.opacity(0.55), radius: 12, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quark Theater")
                            .font(.system(size: 38, weight: .bold))
                        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2"
                        Text("版本：V\(appVersion.replacingOccurrences(of: ".", with: "-")) · Apple TV 原生私人影院")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 20) {
                    Text("产品与设计理念").font(.title3.bold())
                    Text("Quark Theater（Mujio）专为 Apple TV 4K 大屏影音体验设计。支持聚合云盘与家庭 NAS 存储，自动进行海报墙元数据刮削，并通过硬件解码实现 4K HDR / 杜比视界高品质播放。")
                        .font(.body)
                        .foregroundStyle(BrandPalette.glassWhite.opacity(0.85))
                        .lineSpacing(6)

                    Divider().background(Color.white.opacity(0.1))

                    Text("隐私与安全承诺").font(.title3.bold())
                    Text("• 账号 Token、密码与 Cookie 严格加密存储于 Apple TV 系统 Keychain，绝不上传至任何第三方服务器。\n• 移除本地存储源仅清理电视本地配置，绝不向远端发送任何文件修改或删除请求。\n• 诊断日志自动脱敏，不记录任何密码或完整流媒体带签名参数。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)

                    Divider().background(Color.white.opacity(0.1))

                    Text("开源与致谢").font(.title3.bold())
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• KSPlayer：强大稳定的 Apple 全平台视频播放框架")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("• FFmpegKit：工业级多媒体编解码与流解复用底层库")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("• The Movie Database (TMDB)：开放的影视元数据与海报服务")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(32)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                .focusSection()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
        }
        .onExitCommand(perform: onBack)
    }
}
