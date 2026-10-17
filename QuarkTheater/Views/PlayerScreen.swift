import AVKit
import SwiftUI

@MainActor
struct PlayerScreen: View {
    @StateObject private var coordinator: PlaybackCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var showDrawer = false
    @State private var showHintPill = true
    @State private var selectedDrawerTab: DrawerTab = .episodes
    @FocusState private var isDrawerFocused: Bool

    private enum DrawerTab: String, CaseIterable, Identifiable {
        case episodes = "选集列表"
        case subtitles = "字幕"
        case audio = "音轨"
        var id: String { rawValue }
    }

    init(client: QuarkClient, accountID: String, file: CloudFile,
         queue: [CloudFile] = [], automaticallyPlayNext: Bool = false,
         history: HistoryRepository, diagnostics: Diagnostics) {
        _coordinator = StateObject(wrappedValue: PlaybackCoordinator(
            client: client,
            accountID: accountID,
            file: file,
            queue: queue,
            automaticallyPlayNext: automaticallyPlayNext,
            history: history,
            diagnostics: diagnostics
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            // 1. Full-screen Video Player
            if let player = coordinator.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if coordinator.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.8)
                    Text("正在连接夸克云端视频流…")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("无法开始播放")
                        .font(.title2.bold())
                    if let message = coordinator.message {
                        Text(message)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 800)
                    }
                    HStack(spacing: 20) {
                        Button("重新尝试") { coordinator.retry() }
                            .buttonStyle(.borderedProminent)
                        Button("返回") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            // 2. Bottom Drawer Trigger Pill (shown when drawer is closed and video is loaded, auto fades after 3s)
            if !showDrawer && coordinator.player != nil && showHintPill {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showDrawer = true
                        showHintPill = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.up.circle.fill")
                        Text("按 ▼ 或点击打开选集 / 音轨 / 字幕")
                            .font(.headline)
                        if coordinator.canPlayNext {
                            Text("· 可直接下一集")
                                .font(.caption)
                                .foregroundStyle(.cyan)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.borderless)
                .padding(.bottom, 36)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // 3. Sliding Bottom Control Drawer
            if showDrawer {
                VStack(spacing: 20) {
                    // Drawer Header
                    HStack(alignment: .center, spacing: 24) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.currentPlayingFile.name)
                                .font(.title3.bold())
                                .lineLimit(1)
                            Text("播放清单共 \(coordinator.playlistQueue.count) 集 · 字幕 \(coordinator.subtitleOptions.count) 轨 · 音频 \(coordinator.audioOptions.count) 轨")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Picker("类别", selection: $selectedDrawerTab) {
                            ForEach(DrawerTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 500)

                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showDrawer = false
                            }
                        } label: {
                            Label("收起", systemImage: "chevron.down.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)

                    Divider()

                    // Tab Content
                    Group {
                        switch selectedDrawerTab {
                        case .episodes:
                            episodesView
                        case .subtitles:
                            subtitlesView
                        case .audio:
                            audioView
                        }
                    }
                    .frame(minHeight: 180)
                }
                .padding(32)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .focused($isDrawerFocused)
            }
        }
        .task {
            await coordinator.start()
            // Auto-dismiss the hint pill after 3 seconds as requested
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.easeOut(duration: 0.6)) {
                showHintPill = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { coordinator.saveProgress() }
        }
        .onDisappear { coordinator.stop() }
        .onMoveCommand { direction in
            if direction == .down && !showDrawer {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showDrawer = true
                    showHintPill = false
                }
            } else if direction == .up && showDrawer {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showDrawer = false
                }
            }
        }
    }

    // MARK: - Episodes Drawer View
    @ViewBuilder
    private var episodesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                if coordinator.canPlayNext {
                    Button {
                        coordinator.playNext()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.cyan)
                            Text("直接播放下一集")
                                .font(.headline)
                            Text("快速跳集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 20)
                        .padding(.horizontal, 28)
                        .frame(width: 220, height: 140)
                        .background(Color.cyan.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.cyan, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(coordinator.playlistQueue) { file in
                    let isCurrent = file.fileId == coordinator.currentPlayingFile.fileId
                    Button {
                        coordinator.playFile(file)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if isCurrent {
                                    Label("播放中", systemImage: "play.circle.fill")
                                        .font(.caption.bold())
                                        .foregroundStyle(.cyan)
                                } else {
                                    Image(systemName: "film")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(file.fileExtension.uppercased())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(file.name)
                                .font(.subheadline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(width: 260, height: 140)
                        .background(isCurrent ? Color.cyan.opacity(0.12) : Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isCurrent ? Color.cyan : Color.white.opacity(0.1), lineWidth: isCurrent ? 2 : 1)
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Subtitles Drawer View
    @ViewBuilder
    private var subtitlesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                // Option: Off
                let isOff = coordinator.selectedSubtitleIndex == nil
                Button {
                    coordinator.selectSubtitle(nil)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isOff ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOff ? .cyan : .secondary)
                        Text("关闭字幕")
                            .font(.headline)
                    }
                    .padding(20)
                    .frame(width: 200, height: 100)
                    .background(isOff ? Color.cyan.opacity(0.15) : Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(isOff ? Color.cyan : Color.white.opacity(0.1), lineWidth: isOff ? 2 : 1)
                    )
                }
                .buttonStyle(.borderless)

                if coordinator.subtitleOptions.isEmpty {
                    Text("未检测到内嵌字幕轨，支持外挂 SRT/ASS 格式。")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                } else {
                    ForEach(coordinator.subtitleOptions.indices, id: \.self) { index in
                        let isSelected = coordinator.selectedSubtitleIndex == index
                        let option = coordinator.subtitleOptions[index]
                        Button {
                            coordinator.selectSubtitle(index)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? .cyan : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.displayName)
                                        .font(.headline)
                                    Text("字幕轨 #\(index + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(20)
                            .frame(width: 240, height: 100)
                            .background(isSelected ? Color.cyan.opacity(0.15) : Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Audio Drawer View
    @ViewBuilder
    private var audioView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                if coordinator.audioOptions.isEmpty {
                    Text("当前使用系统默认立体声音频流。")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                } else {
                    ForEach(coordinator.audioOptions.indices, id: \.self) { index in
                        let isSelected = coordinator.selectedAudioIndex == index
                        let option = coordinator.audioOptions[index]
                        Button {
                            coordinator.selectAudio(index)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "speaker.wave.3.fill" : "speaker.wave.1")
                                    .font(.title2)
                                    .foregroundStyle(isSelected ? .cyan : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.displayName)
                                        .font(.headline)
                                    Text("音轨 #\(index + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(20)
                            .frame(width: 240, height: 100)
                            .background(isSelected ? Color.cyan.opacity(0.15) : Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}
