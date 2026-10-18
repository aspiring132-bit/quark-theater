import AVKit
import KSPlayer
import SwiftUI

@MainActor
struct PlayerScreen: View {
    @StateObject private var coordinator: PlaybackCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var showDrawer = false
    @State private var showHintPill = true
    @State private var selectedDrawerTab: DrawerTab = .episodes
    @State private var isSeeking = false
    @State private var seekDismissTask: Task<Void, Never>?
    @State private var hintDismissTask: Task<Void, Never>?
    private let diagnostics: Diagnostics

    @FocusState private var focusedTarget: PlayerFocusTarget?

    private enum DrawerTab: String, CaseIterable, Identifiable {
        case episodes = "选集列表"
        case subtitles = "字幕"
        case audio = "音轨"
        var id: String { rawValue }
    }

    init(client: QuarkClient, accountID: String, file: CloudFile,
         queue: [CloudFile] = [], automaticallyPlayNext: Bool = false,
         history: HistoryRepository, diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
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

            // 1. Full-screen Video Player (KSPlayer FFmpeg or Native AVPlayer)
            if let ksURL = coordinator.ksPlayerURL, let ksOptions = coordinator.ksPlayerOptions {
                KSVideoPlayer(coordinator: coordinator.ksCoordinator, url: ksURL, options: ksOptions)
                    .ignoresSafeArea()
            } else if let player = coordinator.player {
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

            if coordinator.activeEngine == .ksplayer, !coordinator.ksSubtitleParts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(coordinator.ksSubtitleParts) { part in
                        if let image = part.image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 900, maxHeight: 240)
                        } else if let text = part.text {
                            Text(AttributedString(text))
                                .font(.title3)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .shadow(color: .black, radius: 2)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.bottom, 110)
                .allowsHitTesting(false)
            }

            // 2. Bottom Drawer Trigger Pill (auto fades after 3s)
            if !showDrawer && coordinator.hasActivePlayer && showHintPill {
                Button {
                    openDrawer()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.up.circle.fill")
                        Text("按 ▼ 打开选集 / 字幕 / 音轨")
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
                .focused($focusedTarget, equals: .drawerTrigger)
                .padding(.bottom, 36)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            // 3. Sliding Bottom Control Drawer
            if showDrawer {
                drawerPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Adaptive Network Speed Badge: appears when buffering or dragging progress bar, fades out when HUD hides
            if (coordinator.isBuffering || isSeeking || coordinator.isLoading) {
                speedBadgeView
                    .padding(.top, 40)
                    .padding(.trailing, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .onMoveCommand { direction in
            handleMoveCommand(direction)
        }
        .task {
            await coordinator.start()
            hintDismissTask?.cancel()
            hintDismissTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.6)) { showHintPill = false }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { coordinator.saveProgress() }
        }
        .onDisappear { coordinator.stop() }
        .onChange(of: focusedTarget) { _, target in
            if let target { diagnostics.recordFocusTransition(FocusDiagnostics.target(for: target)) }
        }
        .onPlayPauseCommand {
            coordinator.togglePlayPause()
        }
    }

    // MARK: - Remote Navigation Handler
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .down:
            if !showDrawer {
                openDrawer()
            } else if isTabFocus {
                // Move focus from tab bar down into content area
                focusedTarget = defaultContentTarget
            }
        case .up:
            if showDrawer {
                if !isTabFocus {
                    // Move focus back up to tab bar
                    focusedTarget = .drawerTab(selectedDrawerTab.rawValue)
                } else {
                    // Already on tab bar — close drawer
                    closeDrawer()
                }
            }
        case .left, .right:
            if !showDrawer {
                let seekDirection: PlayerSeekDirection = direction == .left ? .backward : .forward
                coordinator.seek(direction: seekDirection, interval: PlayerSeekPreference.current)
                triggerSeeking()
            }
        default:
            break
        }
    }

    private var isTabFocus: Bool {
        guard let focusedTarget else { return true }
        if case .drawerTab = focusedTarget { return true }
        return focusedTarget == .closeDrawer || focusedTarget == .silentMarker
    }

    private var defaultContentTarget: PlayerFocusTarget? {
        switch selectedDrawerTab {
        case .episodes:
            if coordinator.canPlayNext { return .nextEpisode }
            return coordinator.playlistQueue.first.map { .episode($0.fileId) }
        case .subtitles:
            return .subtitle("off")
        case .audio:
            let count = coordinator.activeEngine == .ksplayer ? coordinator.ksAudioOptions.count : coordinator.audioOptions.count
            return count > 0 ? .audio("0") : nil
        }
    }

    private func openDrawer() {
        hintDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showDrawer = true
            showHintPill = false
        }
        // Give a brief moment for views to appear, then set focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedTarget = .drawerTab(selectedDrawerTab.rawValue)
        }
    }

    private func closeDrawer() {
        hintDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showDrawer = false
            showHintPill = true
        }
        focusedTarget = nil
        DispatchQueue.main.async {
            if !showDrawer { focusedTarget = .drawerTrigger }
        }
    }

    // MARK: - Drawer Panel
    @ViewBuilder
    private var drawerPanel: some View {
        VStack(spacing: 0) {
            // ── Tab Bar Row ─────────────────────────────────────────────
            // Each tab is an individually focusable Button so that L/R
            // on the remote cycles through 选集列表 / 字幕 / 音轨 / 收起.
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.currentPlayingFile.name)
                        .font(.title3.bold())
                        .lineLimit(1)
                    Text("共 \(coordinator.playlistQueue.count) 集 · 字幕 \(coordinator.subtitleTrackNames.count) 轨 · 音频 \(coordinator.audioTrackNames.count) 轨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Tab selector buttons — focusable individually
                HStack(spacing: 8) {
                    ForEach(DrawerTab.allCases) { tab in
                        tabButton(tab)
                    }
                    // Close / collapse button in same row
                    Button {
                        closeDrawer()
                    } label: {
                        Label("收起", systemImage: "chevron.down.circle.fill")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTarget, equals: .closeDrawer)

                    Button {
                        coordinator.markSilent()
                    } label: {
                        Label("标记无声", systemImage: coordinator.lastSilentMarkerDate == nil ? "speaker.slash" : "checkmark.circle")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedTarget, equals: .silentMarker)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()
                .padding(.horizontal, 24)

            // ── Content Row ─────────────────────────────────────────────
            Group {
                switch selectedDrawerTab {
                case .episodes: episodesView
                case .subtitles: subtitlesView
                case .audio: audioView
                }
            }
            .frame(minHeight: 180)
            .padding(.top, 4)
        }
        .padding(.bottom, 28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    // MARK: - Tab Button
    @ViewBuilder
    private func tabButton(_ tab: DrawerTab) -> some View {
        let isSelected = selectedDrawerTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedDrawerTab = tab
            }
            // Move focus to content so the user can immediately navigate items
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedTarget = defaultContentTarget
            }
        } label: {
            Text(tab.rawValue)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.cyan.opacity(0.25) : Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.cyan : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.borderless)
        .focused($focusedTarget, equals: .drawerTab(tab.rawValue))
    }

    // MARK: - Episodes Content Row
    @ViewBuilder
    private var episodesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                if coordinator.canPlayNext {
                    Button {
                        coordinator.playNext()
                        closeDrawer()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.cyan)
                            Text("下一集")
                                .font(.headline)
                        }
                        .padding(.vertical, 18)
                        .padding(.horizontal, 24)
                        .frame(width: 180, height: 120)
                        .background(Color.cyan.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.cyan, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.borderless)
                    .focused($focusedTarget, equals: .nextEpisode)
                }

                ForEach(coordinator.playlistQueue) { file in
                    let isCurrent = file.fileId == coordinator.currentPlayingFile.fileId
                    Button {
                        coordinator.playFile(file)
                        closeDrawer()
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
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
                        .padding(14)
                        .frame(width: 240, height: 120)
                        .background(isCurrent ? Color.cyan.opacity(0.12) : Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isCurrent ? Color.cyan : Color.white.opacity(0.1),
                                        lineWidth: isCurrent ? 2 : 1)
                        )
                    }
                    .buttonStyle(.borderless)
                    .focused($focusedTarget, equals: .episode(file.fileId))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Subtitles Content Row
    @ViewBuilder
    private var subtitlesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                let isOff = coordinator.selectedSubtitleIndex == nil
                Button {
                    coordinator.selectSubtitle(nil)
                } label: {
                    subtitleAudioLabel(
                        icon: isOff ? "checkmark.circle.fill" : "circle",
                        title: "关闭字幕",
                        subtitle: "关",
                        isSelected: isOff
                    )
                }
                .buttonStyle(.borderless)
                .focused($focusedTarget, equals: .subtitle("off"))

                let names = coordinator.subtitleTrackNames
                if names.isEmpty {
                    Text("未检测到内嵌字幕轨，支持外挂 SRT/ASS 格式。")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                } else {
                    ForEach(names.indices, id: \.self) { index in
                        let isSelected = coordinator.selectedSubtitleIndex == index
                        Button {
                            coordinator.selectSubtitle(index)
                        } label: {
                            subtitleAudioLabel(
                                icon: isSelected ? "checkmark.circle.fill" : "circle",
                                title: names[index],
                                subtitle: "字幕轨 #\(index + 1)",
                                isSelected: isSelected
                            )
                        }
                        .buttonStyle(.borderless)
                        .focused($focusedTarget, equals: .subtitle(String(index)))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Audio Content Row
    @ViewBuilder
    private var audioView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                let names = coordinator.audioTrackNames
                if names.isEmpty {
                    Text("当前使用系统默认立体声音频流。")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                } else {
                    ForEach(names.indices, id: \.self) { index in
                        let isSelected = coordinator.selectedAudioIndex == index
                        Button {
                            coordinator.selectAudio(index)
                        } label: {
                            subtitleAudioLabel(
                                icon: isSelected ? "speaker.wave.3.fill" : "speaker.wave.1",
                                title: names[index],
                                subtitle: "音轨 #\(index + 1)",
                                isSelected: isSelected
                            )
                        }
                        .buttonStyle(.borderless)
                        .focused($focusedTarget, equals: .audio(String(index)))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Shared Item Label
    @ViewBuilder
    private func subtitleAudioLabel(icon: String, title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isSelected ? .cyan : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(minWidth: 200, minHeight: 90)
        .background(isSelected ? Color.cyan.opacity(0.15) : Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.cyan : Color.white.opacity(0.1),
                        lineWidth: isSelected ? 2 : 1)
        )
    }

    // MARK: - Speed Badge View
    @ViewBuilder
    private var speedBadgeView: some View {
        let speed = coordinator.networkSpeedText
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.fill")
                .foregroundStyle(.cyan)
            if coordinator.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                Text(speed.isEmpty ? "正在缓冲" : "缓冲中 · \(speed)")
                    .font(.caption.bold())
            } else {
                Text(speed.isEmpty ? "夸克高速专线" : speed)
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
    }

    private func triggerSeeking() {
        withAnimation(.easeInOut(duration: 0.2)) { isSeeking = true }
        seekDismissTask?.cancel()
        seekDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.3)) { isSeeking = false }
        }
    }
}
