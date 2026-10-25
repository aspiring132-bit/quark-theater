import SwiftUI

@MainActor
struct PlaybackSettingsScreen: View {
    var onBack: () -> Void = {}
    @AppStorage("autoPlayNextEpisode") private var autoPlayNextEpisode = true
    @AppStorage(PlayerSeekPreference.key) private var seekInterval = PlayerSeekPreference.defaultInterval

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
                    Text("播放偏好")
                        .font(.system(size: 38, weight: .bold))
                    Text("调整连续播放与遥控器快进/快退步长。")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("剧集自动连播下一集", isOn: $autoPlayNextEpisode)
                            .frame(maxWidth: 800)
                        Text("当前剧集播放完毕后，自动无缝串流下一集。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider().background(Color.white.opacity(0.1))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("快进 / 快退跳过时长").font(.headline)
                        Picker("跳过时长", selection: $seekInterval) {
                            Text("10 秒").tag(10)
                            Text("15 秒").tag(15)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 800)
                        .onChange(of: seekInterval) { _, value in
                            if value != 10 && value != 15 {
                                seekInterval = PlayerSeekPreference.defaultInterval
                            }
                        }
                        Text("轻点遥控器触控板边缘或方向键时的进度跳转间隔。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                .focusSection()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(60)
        }
        .onExitCommand(perform: onBack)
        .task {
            if seekInterval != 10 && seekInterval != 15 {
                seekInterval = PlayerSeekPreference.defaultInterval
            }
        }
    }
}
