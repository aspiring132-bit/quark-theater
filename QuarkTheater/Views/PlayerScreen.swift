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
    private let backdropURL: URL?

    @FocusState private var focusedTarget: PlayerFocusTarget?

    private enum DrawerTab: String, CaseIterable, Identifiable {
        case episodes = "选集"
        case subtitles = "字幕"
        case audio = "音轨"
        var id: String { rawValue }
    }

    init(client: QuarkClient, accountID: String, file: CloudFile,
         queue: [CloudFile] = [], automaticallyPlayNext: Bool = false,
         history: HistoryRepository, diagnostics: Diagnostics,
         backdropURL: URL? = nil) {
        self.diagnostics = diagnostics
        self.backdropURL = backdropURL
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

            // 1. Full-screen Video Player (KSPlayer FFmpeg Sole Engine)
            if let ksURL = coordinator.ksPlayerURL, let ksOptions = coordinator.ksPlayerOptions {
                KSVideoPlayer(coordinator: coordinator.ksCoordinator, url: ksURL, options: ksOptions)
                    .ignoresSafeArea()
                    .allowsHitTesting(!showDrawer)
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

            if !coordinator.ksSubtitleParts.isEmpty {
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
        .onExitCommand {
            if showDrawer {
                closeDrawer()
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Remote Navigation Handler
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        let state = PlayerInputState(
            isDrawerOpen: showDrawer,
            selectedDrawerTab: selectedDrawerTab.rawValue,
            focusedTarget: focusedTarget,
            canPlayNext: coordinator.canPlayNext,
            currentPlaybackTime: 0,
            duration: 0,
            episodeFileIDs: coordinator.playlistQueue.map(\.fileId),
            subtitleTrackIDs: ["off"] + coordinator.subtitleTrackNames.indices.map(String.init),
            audioTrackIDs: coordinator.audioTrackNames.indices.map(String.init)
        )
        let action = PlayerInputReducer.reduce(state: state, direction: direction, seekInterval: PlayerSeekPreference.current)
        switch action {
        case .openDrawer:
            openDrawer()
        case .closeDrawer:
            closeDrawer()
        case .focusTarget(let target):
            focusedTarget = target
            if case .drawerTab(let tabName) = target, let tab = DrawerTab(rawValue: tabName) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedDrawerTab = tab
                }
            }
        case .seek(let dir, let interval):
            coordinator.seek(direction: dir, interval: interval)
            triggerSeeking()
        case .togglePlayPause:
            coordinator.togglePlayPause()
        case .none:
            break
        }
    }

    private var isTabFocus: Bool {
        guard let focusedTarget else { return true }
        if case .drawerTab = focusedTarget { return true }
        return false
    }

    private var defaultContentTarget: PlayerFocusTarget? {
        switch selectedDrawerTab {
        case .episodes:
            if coordinator.canPlayNext { return .nextEpisode }
            return coordinator.playlistQueue.first.map { .episode($0.fileId) }
        case .subtitles:
            return .subtitle("off")
        case .audio:
            let count = coordinator.ksAudioOptions.count
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
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.currentPlayingFile.name)
                        .font(.title3.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("共 \(coordinator.playlistQueue.count) 集 · 字幕 \(coordinator.subtitleTrackNames.count) 轨 · 音频 \(coordinator.audioTrackNames.count) 轨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 650, alignment: .leading)

                Spacer()

                // Horizontal Tab selector buttons: [选集]  [字幕]  [音轨]
                HStack(spacing: 16) {
                    ForEach(DrawerTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 18)

            Divider()
                .padding(.horizontal, 28)

            // ── Content Row ─────────────────────────────────────────────
            Group {
                switch selectedDrawerTab {
                case .episodes: episodesView
                case .subtitles: subtitlesView
                case .audio: audioView
                }
            }
            .frame(minHeight: 240)
            .padding(.top, 8)
        }
        .padding(.bottom, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    // MARK: - Tab Button (Horizontal Pill with Focus Highlight)
    @ViewBuilder
    private func tabButton(_ tab: DrawerTab) -> some View {
        let isSelected = selectedDrawerTab == tab
        let isFocused = focusedTarget == .drawerTab(tab.rawValue)

        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedDrawerTab = tab
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                focusedTarget = defaultContentTarget
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tabIcon(for: tab))
                    .font(.subheadline)
                Text(tab.rawValue)
                    .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                    .fixedSize()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isFocused {
                        Color.white
                    } else if isSelected {
                        Color.cyan.opacity(0.28)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .foregroundStyle(isFocused ? Color.black : (isSelected ? Color.cyan : Color.white))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isFocused ? Color.white : (isSelected ? Color.cyan : Color.white.opacity(0.15)),
                        lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : 1)
                    )
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.borderless)
        .focused($focusedTarget, equals: .drawerTab(tab.rawValue))
    }

    private func tabIcon(for tab: DrawerTab) -> String {
        switch tab {
        case .episodes: return "film.stack"
        case .subtitles: return "captions.bubble"
        case .audio: return "waveform"
        }
    }

    // MARK: - Episodes Content Row
    @ViewBuilder
    private var episodesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollViewReader { proxy in
                HStack(spacing: 20) {
                    if coordinator.canPlayNext {
                        nextEpisodeButton
                    }

                    ForEach(coordinator.playlistQueue) { file in
                        DrawerEpisodeCard(
                            file: file,
                            isCurrent: file.fileId == coordinator.currentPlayingFile.fileId,
                            isTargetFocused: focusedTarget == .episode(file.fileId),
                            backdropURL: backdropURL
                        ) {
                            coordinator.playFile(file)
                            closeDrawer()
                        }
                        .id(PlayerFocusTarget.episode(file.fileId))
                        .focused($focusedTarget, equals: .episode(file.fileId))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .onChange(of: focusedTarget) { _, target in
                    if let target {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var nextEpisodeButton: some View {
        let isFocused = focusedTarget == .nextEpisode
        return Button {
            coordinator.playNext()
            closeDrawer()
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isFocused ? Color.cyan : Color.cyan.opacity(0.2))
                        .frame(width: 72, height: 72)
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(isFocused ? Color.black : Color.cyan)
                }

                VStack(spacing: 4) {
                    Text("播放下一集")
                        .font(.headline.weight(isFocused ? .bold : .semibold))
                        .foregroundStyle(isFocused ? .white : .primary)
                    Text("自动连播")
                        .font(.caption2)
                        .foregroundStyle(isFocused ? Color.white.opacity(0.8) : .secondary)
                }
            }
            .frame(width: 200, height: 190)
            .background(isFocused ? Color.white.opacity(0.15) : Color.cyan.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isFocused ? Color.cyan : Color.cyan.opacity(0.5), lineWidth: isFocused ? 3.5 : 1.5)
            )
            .shadow(
                color: isFocused ? Color.cyan.opacity(0.55) : Color.clear,
                radius: 14,
                x: 0,
                y: 6
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.borderless)
        .id(PlayerFocusTarget.nextEpisode)
        .focused($focusedTarget, equals: .nextEpisode)
    }

    // MARK: - Subtitles Content Row
    @ViewBuilder
    private var subtitlesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollViewReader { proxy in
                HStack(spacing: 16) {
                    let isOff = coordinator.selectedSubtitleIndex == nil
                    let isOffFocused = focusedTarget == .subtitle("off")
                    subtitleAudioCard(
                        icon: isOff ? "checkmark.circle.fill" : "circle",
                        title: "关闭字幕",
                        subtitle: "关",
                        isSelected: isOff,
                        isFocused: isOffFocused
                    ) {
                        coordinator.selectSubtitle(nil)
                    }
                    .id(PlayerFocusTarget.subtitle("off"))
                    .focused($focusedTarget, equals: .subtitle("off"))

                    let names = coordinator.subtitleTrackNames
                    if names.isEmpty {
                        Text("未检测到内嵌字幕轨，支持外挂 SRT/ASS 格式。")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    } else {
                        ForEach(names.indices, id: \.self) { index in
                            let isSelected = coordinator.selectedSubtitleIndex == index
                            let isFocused = focusedTarget == .subtitle(String(index))
                            subtitleAudioCard(
                                icon: isSelected ? "checkmark.circle.fill" : "circle",
                                title: names[index],
                                subtitle: "字幕轨 #\(index + 1)",
                                isSelected: isSelected,
                                isFocused: isFocused
                            ) {
                                coordinator.selectSubtitle(index)
                            }
                            .id(PlayerFocusTarget.subtitle(String(index)))
                            .focused($focusedTarget, equals: .subtitle(String(index)))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .onChange(of: focusedTarget) { _, target in
                    if let target {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Audio Content Row
    @ViewBuilder
    private var audioView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScrollViewReader { proxy in
                HStack(spacing: 16) {
                    let names = coordinator.audioTrackNames
                    if names.isEmpty {
                        Text("当前使用系统默认立体声音频流。")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    } else {
                        ForEach(names.indices, id: \.self) { index in
                            let isSelected = coordinator.selectedAudioIndex == index
                            let isFocused = focusedTarget == .audio(String(index))
                            subtitleAudioCard(
                                icon: isSelected ? "speaker.wave.3.fill" : "speaker.wave.1",
                                title: names[index],
                                subtitle: "音轨 #\(index + 1)",
                                isSelected: isSelected,
                                isFocused: isFocused
                            ) {
                                coordinator.selectAudio(index)
                            }
                            .id(PlayerFocusTarget.audio(String(index)))
                            .focused($focusedTarget, equals: .audio(String(index)))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
                .onChange(of: focusedTarget) { _, target in
                    if let target {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared Subtitle/Audio Card
    @ViewBuilder
    private func subtitleAudioCard(
        icon: String,
        title: String,
        subtitle: String,
        isSelected: Bool,
        isFocused: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isFocused ? Color.black : (isSelected ? Color.cyan : Color.secondary))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(isFocused || isSelected ? .bold : .medium))
                        .foregroundStyle(isFocused ? Color.black : Color.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.bold())
                        .foregroundStyle(isFocused ? Color.black : Color.cyan)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minWidth: 220, maxWidth: 320, minHeight: 76)
            .background(
                Group {
                    if isFocused {
                        Color.white
                    } else if isSelected {
                        Color.cyan.opacity(0.2)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isFocused ? Color.white : (isSelected ? Color.cyan : Color.white.opacity(0.12)),
                        lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : 1)
                    )
            )
            .shadow(
                color: isFocused ? Color.white.opacity(0.35) : Color.clear,
                radius: 12,
                x: 0,
                y: 4
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.borderless)
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

// MARK: - Drawer Episode Card with Whole-Card Focus & Thumbnail Preview
private struct DrawerEpisodeCard: View {
    let file: CloudFile
    let isCurrent: Bool
    let isTargetFocused: Bool
    let backdropURL: URL?
    let action: () -> Void

    @Environment(\.isFocused) private var isEnvironmentFocused

    private var isFocused: Bool {
        isTargetFocused || isEnvironmentFocused
    }

    private var parsed: ParsedMediaName {
        FilenameParser.parse(file.name)
    }

    private var cardTitle: String {
        if let ep = parsed.episodeNumber {
            return "第 \(ep) 集 · \(file.name)"
        }
        return file.name
    }

    private var cardBorderColor: Color {
        if isFocused { return Color.cyan }
        if isCurrent { return Color.cyan.opacity(0.7) }
        return Color.white.opacity(0.12)
    }

    private var cardBorderWidth: CGFloat {
        if isFocused { return 3.5 }
        if isCurrent { return 2.0 }
        return 1.0
    }

    private var infoBackgroundColor: Color {
        if isFocused { return Color.white.opacity(0.18) }
        if isCurrent { return Color.cyan.opacity(0.14) }
        return Color.white.opacity(0.06)
    }

    private var sizeString: String {
        ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
    }

    private var tagString: String {
        let lower = file.name.lowercased()
        if lower.contains("4k") || lower.contains("2160p") { return "4K" }
        if lower.contains("1080p") { return "1080P" }
        if lower.contains("720p") { return "720P" }
        return file.fileExtension.uppercased()
    }

    @ViewBuilder
    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cardTitle)
                .font(.subheadline.weight(isFocused ? .bold : .medium))
                .foregroundStyle(isFocused ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Text(sizeString)
                    .font(.caption2)
                    .foregroundStyle(isFocused ? Color.white.opacity(0.9) : Color.secondary)

                Spacer()

                Text(tagString)
                    .font(.caption2.bold())
                    .foregroundStyle(isCurrent ? Color.cyan : (isFocused ? Color.white : Color.secondary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, height: 75, alignment: .leading)
        .background(infoBackgroundColor)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                thumbnailBanner
                    .frame(width: 280, height: 115)
                    .clipped()

                infoArea
            }
            .frame(width: 280, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(cardBorderColor, lineWidth: cardBorderWidth)
            )
            .shadow(
                color: isFocused ? Color.cyan.opacity(0.6) : Color.black.opacity(0.35),
                radius: isFocused ? 14 : 6,
                x: 0,
                y: isFocused ? 6 : 2
            )
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var thumbnailBanner: some View {
        ZStack(alignment: .center) {
            if let backdropURL {
                AsyncImage(url: backdropURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderBackground
                }
            } else {
                placeholderBackground
            }

            // Dark vignette overlay
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Center Play Icon (grows on focus)
            Image(systemName: isCurrent ? "waveform" : "play.circle.fill")
                .font(.system(size: isFocused ? 34 : 26))
                .foregroundStyle(isCurrent ? Color.cyan : (isFocused ? Color.white : Color.white.opacity(0.65)))
                .shadow(color: .black.opacity(0.8), radius: 4)

            // Top Badges
            VStack {
                HStack {
                    if isCurrent {
                        HStack(spacing: 4) {
                            Circle().fill(Color.cyan).frame(width: 6, height: 6)
                            Text("播放中")
                                .font(.caption2.bold())
                                .foregroundStyle(.cyan)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    } else if let ep = parsed.episodeNumber {
                        Text("第 \(ep) 集")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer()

                    Text(file.fileExtension.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(isFocused ? Color.cyan : Color.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(8)

                Spacer()
            }
        }
    }

    private var placeholderBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.14, green: 0.17, blue: 0.24),
                Color(red: 0.08, green: 0.10, blue: 0.16)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "film")
                .font(.system(size: 32))
                .foregroundStyle(Color.white.opacity(0.1))
        )
    }
}
