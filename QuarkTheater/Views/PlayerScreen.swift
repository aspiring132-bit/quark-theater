import AVKit
import SwiftUI

@MainActor
struct PlayerScreen: View {
    @StateObject private var coordinator: PlaybackCoordinator
    @Environment(\.scenePhase) private var scenePhase
    private let file: CloudFile

    init(client: QuarkClient, accountID: String, file: CloudFile,
         queue: [CloudFile] = [], automaticallyPlayNext: Bool = false,
         history: HistoryRepository, diagnostics: Diagnostics) {
        self.file = file
        _coordinator = StateObject(wrappedValue: PlaybackCoordinator(client: client,
            accountID: accountID, file: file, queue: queue, automaticallyPlayNext: automaticallyPlayNext,
            history: history, diagnostics: diagnostics))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(file.name).font(.title2).lineLimit(2)
            if let player = coordinator.player { VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit) }
            else if coordinator.isLoading { ProgressView("正在获取播放地址") }
            else {
                VStack(spacing: 18) {
                    Image(systemName: "play.slash").font(.system(size: 56))
                    Text("无法开始播放").font(.title2)
                }
            }
            if let message = coordinator.message {
                Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button("重新尝试") { coordinator.retry() }
            }
            HStack(spacing: 24) {
                if coordinator.canPlayNext { Button("下一集") { coordinator.playNext() } }
                if !coordinator.audioOptions.isEmpty {
                    Menu("音轨") {
                        ForEach(coordinator.audioOptions.indices, id: \.self) { index in
                            Button(coordinator.audioOptions[index].displayName) { coordinator.selectAudio(index) }
                        }
                    }
                }
                if !coordinator.subtitleOptions.isEmpty {
                    Menu("字幕") {
                        Button("关闭字幕") { coordinator.selectSubtitle(nil) }
                        ForEach(coordinator.subtitleOptions.indices, id: \.self) { index in
                            Button(coordinator.subtitleOptions[index].displayName) { coordinator.selectSubtitle(index) }
                        }
                    }
                }
            }
            Text("播放地址临时获取；AVPlayer 请求头兼容性和媒体格式仍需真机验证。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(48)
            .task { await coordinator.start() }
            .onChange(of: scenePhase) { phase in
                if phase == .background || phase == .inactive { coordinator.saveProgress() }
            }
            .onDisappear { coordinator.stop() }
    }
}
