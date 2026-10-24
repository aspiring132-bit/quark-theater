import SwiftUI
import UIKit

@MainActor
struct PlayerScreen: View {
    @StateObject private var coordinator: PlaybackCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var showDrawer = false
    @State private var showHintPill = true
    @State private var selectedDrawerTab: DrawerTab = .episodes
    @State private var isSeeking = false
    @State private var pendingSeekTarget: Double?
    @State private var seekCommitTask: Task<Void, Never>?
    @State private var seekDismissTask: Task<Void, Never>?
    @State private var seekRepeatCount = 0
    @State private var lastSeekDirection: PlayerSeekDirection?
    @State private var lastSeekDate: Date?
    @State private var seekLastInteractionDate: Date?
    @State private var lastBackDate: Date?
    @State private var hintDismissTask: Task<Void, Never>?
    @State private var stillURLByFileID: [String: URL] = [:]
    @State private var episodeTitleByFileID: [String: String] = [:]
    @State private var artworkLoadTask: Task<Void, Never>?
    @State private var defaultArtworkProvider: EpisodeArtworkProvider?
    private let diagnostics: Diagnostics
    private let backdropURL: URL?
    private let episodeMetadataByFileID: [String: ParsedMediaName]
    private let seriesTMDBId: Int?
    private let artworkProvider: EpisodeArtworkProvider?

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
         backdropURL: URL? = nil,
         episodeMetadataByFileID: [String: ParsedMediaName] = [:],
         seriesTMDBId: Int? = nil,
         artworkProvider: EpisodeArtworkProvider? = nil,
         // Narrow UI-test seam: lets a harness observe the real coordinator's
         // state. Never set in production call sites.
         coordinatorObserver: ((PlaybackCoordinator) -> Void)? = nil) {
        self.diagnostics = diagnostics
        self.backdropURL = backdropURL
        self.episodeMetadataByFileID = episodeMetadataByFileID
        self.seriesTMDBId = seriesTMDBId
        self.artworkProvider = artworkProvider
        let playbackCoordinator = PlaybackCoordinator(
            client: client,
            accountID: accountID,
            file: file,
            queue: queue,
            automaticallyPlayNext: automaticallyPlayNext,
            history: history,
            diagnostics: diagnostics
        )
        _coordinator = StateObject(wrappedValue: playbackCoordinator)
        coordinatorObserver?(playbackCoordinator)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            // 1. Full-screen VLC surface. The coordinator owns the engine;
            // this surface is deliberately independent from the drawer/focus tree.
            if coordinator.hasActivePlayer {
                VLCVideoSurface(coordinator: coordinator)
                    .ignoresSafeArea()
                    .allowsHitTesting(!showDrawer)

                // Centered waiting UI: only displayed when truly loading or buffering (BUG-005)
                if coordinator.isBuffering || coordinator.isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.6)
                        Text(coordinator.isBuffering ? "正在缓冲…" : "正在加载…")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .transition(.opacity)
                }
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

            // 2. Bottom Drawer Trigger Pill (auto fades after 3s)
            if !showDrawer && coordinator.hasActivePlayer {
                Button {
                    // OK/Select on the main player screen toggles play/pause, avoiding accidental drawer opening (BUG-009).
                    // Drawer is opened strictly via Down move command.
                    coordinator.togglePlayPause()
                } label: {
                    HStack(spacing: 12) {
                        Text("按 ▼ 打开选集 / 字幕 / 音轨")
                            .font(.headline)
                        if coordinator.canPlayNext {
                            Text("· 可直接下一集")
                                .font(.caption)
                                .foregroundStyle(BrandPalette.glassWhite)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .opacity(showHintPill ? 1 : 0.001)
                }
                .buttonStyle(.plain)
                .focused($focusedTarget, equals: .drawerTrigger)
                .accessibilityIdentifier("player.drawerTrigger")
                // Keep the trigger focusable in the focus tree after the hint fades so
                // it retains focus stably and prevents conditional overlay buttons from stealing focus.
                .allowsHitTesting(true)
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
            // Adaptive Network Speed Badge: appears only during real buffering or loading (BUG-005)
            if (coordinator.isBuffering || coordinator.isLoading) {
                speedBadgeView
                    .padding(.top, 40)
                    .padding(.trailing, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
            if isSeeking {
                seekHUDView
                    .padding(.top, 92)
                    .padding(.trailing, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // F-001: Focusable Skip Intro / Outro Buttons in bottom-trailing corner
            if !showDrawer {
                let time = coordinator.playbackTime
                let duration = coordinator.playbackDuration
                let markers = coordinator.currentEpisodeMarkers

                if let intro = markers.intro, duration > 0, time >= intro.startSeconds && time < min(intro.endSeconds, duration) {
                    Button {
                        coordinator.seek(to: min(intro.endSeconds, duration))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "forward.end.alt.fill")
                                .font(.headline)
                            Text("跳过片头")
                                .font(.headline.weight(.semibold))
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTarget, equals: .skipIntro)
                    .accessibilityIdentifier("player.skipIntroButton")
                    .padding(.trailing, 60)
                    .padding(.bottom, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if let outro = markers.outro, duration > 0, coordinator.canPlayNext, time >= outro.startSeconds && time < min(outro.endSeconds, duration) {
                    Button {
                        coordinator.playNext(manualSelection: true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "forward.end.fill")
                                .font(.headline)
                            Text("跳过片尾")
                                .font(.headline.weight(.semibold))
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTarget, equals: .skipOutro)
                    .accessibilityIdentifier("player.skipOutroButton")
                    .padding(.trailing, 60)
                    .padding(.bottom, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .onMoveCommand { direction in
            handleMoveCommand(direction)
        }
        .task {
            if focusedTarget == nil {
                focusedTarget = .drawerTrigger
            }
            await coordinator.start()
            restartHintDismissTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { coordinator.saveProgress() }
        }
        .onDisappear {
            coordinator.stop()
            artworkLoadTask?.cancel()
        }
        .onChange(of: focusedTarget) { _, target in
            if let target {
                let diagnosticTarget = FocusDiagnostics.target(for: target)
                var metadata: [DiagnosticMetadata] = [.focusTarget(diagnosticTarget)]
                if case .episode(let fileID) = target,
                   let ordinal = coordinator.playlistQueue.firstIndex(where: { $0.fileId == fileID }) {
                    metadata.append(.focusOrdinal(ordinal))
                    metadata.append(.episodeOrdinal(ordinal))
                    if let episodeNumber = episodeMetadataByFileID[fileID]?.episodeNumber {
                        metadata.append(.episodeNumber(episodeNumber))
                    }
                }
                diagnostics.record(category: .navigation, level: .debug, event: .focusChanged,
                                   correlationID: coordinator.playbackCorrelation,
                                   metadata: metadata)
            }
            if let tabName = PlayerInputReducer.selectedTabName(for: target),
               let tab = DrawerTab(rawValue: tabName), tab != selectedDrawerTab {
                // Native focus is the single owner of horizontal drawer
                // movement; synchronize state only, without moving focus.
                selectedDrawerTab = tab
            }
        }
        .onPlayPauseCommand {
            coordinator.togglePlayPause()
        }
        .onExitCommand {
            handleBackCommand()
        }
    }

    private var currentInputState: PlayerInputState {
        PlayerInputState(
            isDrawerOpen: showDrawer,
            selectedDrawerTab: selectedDrawerTab.rawValue,
            focusedTarget: focusedTarget,
            canPlayNext: coordinator.canPlayNext,
            currentPlaybackTime: coordinator.playbackTime,
            duration: coordinator.playbackDuration,
            episodeFileIDs: coordinator.playlistQueue.map(\.fileId),
            currentEpisodeFileID: coordinator.currentPlayingFile.fileId,
            subtitleTrackIDs: ["off"] + coordinator.subtitleTrackNames.indices.map(String.init),
            audioTrackIDs: coordinator.audioTrackNames.indices.map(String.init)
        )
    }

    // MARK: - Remote Navigation Handler
    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        let state = currentInputState
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
            // BUG-004/BUG-007/F-002:
            // 1. Short press uses configured interval (10/15s)
            // 2. Accumulate from previous pending seek target or current playback time
            // 3. Continuous press / hold accelerates step (1x, 2x, 3x, 4x)
            // 4. Avoid double triggering; commit seek target upon release
            let now = Date()
            let isRepeat = lastSeekDirection == dir && (lastSeekDate.map { now.timeIntervalSince($0) < 0.45 } ?? false)
            seekRepeatCount = isRepeat ? min(seekRepeatCount + 1, 4) : 0
            lastSeekDirection = dir
            lastSeekDate = now

            let effectiveInterval = PlayerSeekRepeatPolicy.interval(configured: interval, repeatCount: seekRepeatCount)
            let baseTime = pendingSeekTarget ?? coordinator.playbackTime
            let duration = coordinator.playbackDuration

            if let nextTarget = PlayerSeekMath.target(current: baseTime, direction: dir, interval: effectiveInterval, duration: duration) {
                pendingSeekTarget = nextTarget
            }

            triggerSeeking()

            seekCommitTask?.cancel()
            seekCommitTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                if let target = pendingSeekTarget {
                    coordinator.seek(to: target)
                }
            }
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
            let currentFileID = coordinator.currentPlayingFile.fileId
            if coordinator.playlistQueue.contains(where: { $0.fileId == currentFileID }) {
                return .episode(currentFileID)
            }
            if coordinator.canPlayNext { return .nextEpisode }
            return coordinator.playlistQueue.first.map { .episode($0.fileId) }
        case .subtitles:
            return .subtitle("off")
        case .audio:
            let count = coordinator.audioTracks.count
            return count > 0 ? .audio("0") : nil
        }
    }

    private func openDrawer() {
        hintDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showDrawer = true
            showHintPill = false
        }
        loadEpisodeArtwork()
        // Give a brief moment for views to appear, then set focus
        let currentID = coordinator.activePlayingFileID ?? coordinator.currentPlayingFile.fileId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedTarget = selectedDrawerTab == .episodes
                ? .episode(currentID)
                : .drawerTab(selectedDrawerTab.rawValue)
        }
    }

    // MARK: - Per-Episode Artwork

    /// Resolve TMDB stills for the drawer cards. Only files whose season and
    /// episode are both known participate (confirmed metadata first, filename
    /// parsing as fallback — already projected by callers). One TMDB season
    /// request is issued per season at most, and artwork never blocks
    /// playback or focus.
    private func loadEpisodeArtwork() {
        artworkLoadTask?.cancel()
        guard let seriesTMDBId else { return }
        let provider: EpisodeArtworkProvider
        if let artworkProvider {
            provider = artworkProvider
        } else {
            // Lazily keep one provider so its season cache survives drawer
            // open/close cycles for the whole playback session.
            if defaultArtworkProvider == nil {
                defaultArtworkProvider = EpisodeArtworkProvider(
                    service: TMDBService(diagnostics: diagnostics),
                    apiReadToken: TMDBCredentialStore().effectiveToken()
                )
            }
            provider = defaultArtworkProvider!
        }
        let requests = EpisodeArtworkResolver.requests(
            seriesTMDBId: seriesTMDBId,
            metadataByFileID: episodeMetadataByFileID
        )
        guard !requests.isEmpty else { return }
        artworkLoadTask = Task {
            let urls = await provider.stillURLs(seriesID: seriesTMDBId, requests: requests)
            let service = TMDBService(diagnostics: diagnostics)
            let token = TMDBCredentialStore().effectiveToken()
            let seasons = Set(requests.values.map(\.seasonNumber))
            var namesByFileID: [String: String] = [:]
            for season in seasons {
                if let details = try? await service.seasonDetails(seriesID: seriesTMDBId, seasonNumber: season, apiReadToken: token) {
                    let nameMap = details.episodeNameByEpisode
                    for (fileID, req) in requests where req.seasonNumber == season {
                        if let name = nameMap[req.episodeNumber], !name.isEmpty {
                            namesByFileID[fileID] = name
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            stillURLByFileID = urls
            if !namesByFileID.isEmpty {
                episodeTitleByFileID = namesByFileID
            }
        }
    }

    private func closeDrawer() {
        hintDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showDrawer = false
            showHintPill = true
        }
        restartHintDismissTimer()
        focusedTarget = nil
        DispatchQueue.main.async {
            guard !showDrawer else { return }
            focusedTarget = .drawerTrigger
        }
    }

    private func handleBackCommand() {
        let now = Date()
        if let last = lastBackDate, now.timeIntervalSince(last) < 0.35 {
            return
        }
        lastBackDate = now

        let drawerWasOpen = showDrawer
        let action = PlayerInputReducer.handleBack(state: currentInputState)
        var metadata: [DiagnosticMetadata] = [
            .backDisposition(drawerWasOpen ? .closedDrawer : .dismissedPlayer)
        ]
        let playingID = coordinator.currentPlayingFile.fileId
        if let ordinal = coordinator.playlistQueue.firstIndex(where: { $0.fileId == playingID }) {
            metadata.append(.episodeOrdinal(ordinal))
        }
        if let episodeNumber = episodeMetadataByFileID[playingID]?.episodeNumber {
            metadata.append(.episodeNumber(episodeNumber))
        }
        diagnostics.record(
            category: .navigation,
            level: .debug,
            event: .remoteBack,
            correlationID: coordinator.playbackCorrelation,
            metadata: metadata
        )
        if drawerWasOpen {
            closeDrawer()
        } else {
            dismiss()
        }
    }

    private func restartHintDismissTimer() {
        hintDismissTask?.cancel()
        hintDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { showHintPill = false }
        }
    }

    // Helper to resolve series name, episode number, and title with fallbacks (BUG-008)
    private func resolvedEpisodeTitle(for file: CloudFile) -> (seriesTitle: String?, episodeLabel: String, fullTitle: String) {
        let metadata = episodeMetadataByFileID[file.fileId] ?? FilenameParser.parse(file.name)
        let epNum = metadata.episodeNumber
        let series = !metadata.title.isEmpty ? metadata.title : nil
        let epTitle = episodeTitleByFileID[file.fileId]

        let epLabel: String
        if let epNum {
            epLabel = "第 \(epNum) 集"
        } else {
            epLabel = file.name
        }

        let displayTitle: String
        if let epTitle, !epTitle.isEmpty {
            if let series, let epNum {
                displayTitle = "\(series) 第 \(epNum) 集 · \(epTitle)"
            } else if let epNum {
                displayTitle = "第 \(epNum) 集 · \(epTitle)"
            } else {
                displayTitle = epTitle
            }
        } else if let series, let epNum {
            displayTitle = "\(series) 第 \(epNum) 集 · \(file.name)"
        } else if let epNum {
            displayTitle = "第 \(epNum) 集 · \(file.name)"
        } else {
            displayTitle = file.name
        }

        return (series, epLabel, displayTitle)
    }

    // MARK: - Drawer Panel
    @ViewBuilder
    private var drawerPanel: some View {
        VStack(spacing: 0) {
            // ── Tab Bar Row ─────────────────────────────────────────────
            HStack(alignment: .center, spacing: 24) {
                let headerInfo = resolvedEpisodeTitle(for: coordinator.currentPlayingFile)
                VStack(alignment: .leading, spacing: 6) {
                    Text(headerInfo.fullTitle)
                        .font(.headline.weight(.bold))
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
            .padding(.horizontal, 46)
            .padding(.vertical, 18)

            Divider()
                .padding(.horizontal, 38)

            // ── Content Row ─────────────────────────────────────────────
            Group {
                switch selectedDrawerTab {
                case .episodes: episodesView
                case .subtitles: subtitlesView
                case .audio: audioView
                }
            }
            .frame(minHeight: 180, maxHeight: 300)
            .padding(.top, 8)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: 1600, maxHeight: 500, alignment: .bottom)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
        .focusSection()
        .onExitCommand {
            // Handle Back at the focused drawer's own scope so it closes this
            // panel instead of bubbling out to the player presentation.
            handleBackCommand()
        }
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
                        BrandPalette.glassWhite.opacity(0.1)
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .foregroundStyle(isFocused ? Color.black : BrandPalette.glassWhite)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isFocused ? BrandPalette.glassWhite : (isSelected ? BrandPalette.iceBlue.opacity(0.25) : BrandPalette.glassWhite.opacity(0.15)),
                        lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : 1)
                    )
            )
            .scaleEffect(DrawerButtonFocusStyle.scale(isFocused: isFocused))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($focusedTarget, equals: .drawerTab(tab.rawValue))
        .accessibilityIdentifier("player.tab.\(tab.rawValue)")
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) {
                    if coordinator.canPlayNext {
                        nextEpisodeButton
                    }

                    ForEach(Array(coordinator.playlistQueue.enumerated()), id: \.element.fileId) { index, file in
                        let isCurrent = coordinator.activePlayingFileID.map { file.fileId == $0 }
                            ?? (coordinator.isCurrentPlaybackStarted && file.fileId == coordinator.currentPlayingFile.fileId)
                        let isPending = file.fileId == coordinator.pendingFile?.fileId
                            || (coordinator.isPlaybackTransitionActive && file.fileId == coordinator.currentPlayingFile.fileId)

                        DrawerEpisodeCard(
                            file: file,
                            parsedMetadata: episodeMetadataByFileID[file.fileId],
                            episodeTitle: episodeTitleByFileID[file.fileId],
                            isCurrent: isCurrent,
                            isPending: isPending,
                            // Fallback chain: episode still → series backdrop → placeholder.
                            artworkURL: stillURLByFileID[file.fileId] ?? backdropURL
                        ) {
                            coordinator.playFile(
                                file,
                                selectionOrdinal: index,
                                episodeNumber: episodeMetadataByFileID[file.fileId]?.episodeNumber
                            )
                            closeDrawer()
                        }
                        .id(PlayerFocusTarget.episode(file.fileId))
                        .focused($focusedTarget, equals: .episode(file.fileId))
                        // Index-based identifier: never exposes real cloud file IDs.
                        .accessibilityIdentifier("player.episodeCard.\(index)")
                    }
                }
                .padding(.horizontal, 64)
                // The focused card scales to 1.05. Keep a tall viewport plus
                // breathing room so its top episode/playing badges stay clear
                // of the ScrollView's clipping bounds.
                .padding(.vertical, 24)
            }
            .frame(height: 280)
            .accessibilityIdentifier("player.episodeScroll")
            .onAppear {
                let targetID = coordinator.activePlayingFileID ?? coordinator.currentPlayingFile.fileId
                proxy.scrollTo(PlayerFocusTarget.episode(targetID), anchor: .center)
            }
            .onChange(of: focusedTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private var nextEpisodeButton: some View {
        let isFocused = focusedTarget == .nextEpisode
        return Button {
            coordinator.playNext(manualSelection: true)
            closeDrawer()
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isFocused ? BrandPalette.glassWhite : BrandPalette.glassWhite.opacity(0.08))
                        .frame(width: 72, height: 72)
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(isFocused ? Color.black : BrandPalette.glassWhite)
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
            .background(isFocused ? BrandPalette.glassWhite.opacity(0.15) : BrandPalette.glassWhite.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isFocused ? BrandPalette.glassWhite : BrandPalette.iceBlue.opacity(0.25), lineWidth: isFocused ? 3.5 : 1.5)
            )
            .shadow(
                color: isFocused ? BrandPalette.iceGlow : Color.clear,
                radius: 14,
                x: 0,
                y: 6
            )
            .scaleEffect(DrawerButtonFocusStyle.scale(isFocused: isFocused))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(PlayerFocusTarget.nextEpisode)
        .focused($focusedTarget, equals: .nextEpisode)
        .accessibilityIdentifier("player.nextEpisode")
    }

    // MARK: - Subtitles Content Row
    @ViewBuilder
    private var subtitlesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
            .padding(.horizontal, 44)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Audio Content Row
    @ViewBuilder
    private var audioView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Button {
                    coordinator.markSilent()
                } label: {
                    Label("声音异常", systemImage: "speaker.slash.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(focusedTarget == .silentMarker ? Color.black : BrandPalette.glassWhite)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(focusedTarget == .silentMarker ? Color.white : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BrandPalette.iceBlue.opacity(0.45), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .focused($focusedTarget, equals: .silentMarker)
                .accessibilityIdentifier("player.silentMarker")

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
            .padding(.horizontal, 44)
            .padding(.vertical, 16)
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
                    .foregroundStyle(isFocused ? Color.black : (isSelected ? BrandPalette.glassWhite : BrandPalette.secondaryText))
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
                        .foregroundStyle(isFocused ? Color.black : BrandPalette.glassWhite)
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
                        BrandPalette.glassWhite.opacity(0.08)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isFocused ? BrandPalette.glassWhite : (isSelected ? BrandPalette.iceBlue.opacity(0.25) : BrandPalette.glassWhite.opacity(0.12)),
                        lineWidth: isFocused ? 2.5 : (isSelected ? 1.5 : 1)
                    )
            )
            .shadow(
                color: isFocused ? Color.white.opacity(0.35) : Color.clear,
                radius: 12,
                x: 0,
                y: 4
            )
            .scaleEffect(DrawerButtonFocusStyle.scale(isFocused: isFocused))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Speed Badge View
    @ViewBuilder
    private var speedBadgeView: some View {
        let speed = coordinator.networkSpeedText
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.fill")
                .foregroundStyle(BrandPalette.glassWhite)
            if coordinator.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                Text(speed.isEmpty ? "正在缓冲…" : "缓冲中 · \(speed)")
                    .font(.caption.bold())
            } else if coordinator.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                Text("正在加载…")
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

    @ViewBuilder
    private var seekHUDView: some View {
        let duration = coordinator.playbackDuration
        let current = coordinator.playbackTime
        let target = pendingSeekTarget ?? current
        let bufferedTime = coordinator.bufferedTime
        let bufferedRanges = coordinator.bufferedRanges

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let pending = pendingSeekTarget {
                        let diff = pending - current
                        let diffStr = diff >= 0 ? "+\(Int(diff.rounded()))s" : "\(Int(diff.rounded()))s"
                        HStack(spacing: 6) {
                            Text("跳转目标: \(formatTime(pending))")
                                .font(.headline.weight(.bold).monospacedDigit())
                                .foregroundStyle(BrandPalette.iceBlue)
                            Text("(\(diffStr))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(BrandPalette.iceBlue.opacity(0.85))
                        }
                    }
                    HStack(spacing: 6) {
                        Text("已播放: \(formatTime(current))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white)
                        Text("/ 总时长: \(formatTime(duration))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                if bufferedTime > 0 {
                    Text("已缓冲: \(formatTime(bufferedTime))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }

            // Scrubber Bar with Buffered Ranges and Seek Target
            GeometryReader { geo in
                let width = geo.size.width
                let total = max(duration, 1)

                ZStack(alignment: .leading) {
                    // Track Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 6)

                    // Buffered ranges (multi-range when available)
                    if !bufferedRanges.isEmpty {
                        ForEach(Array(bufferedRanges.enumerated()), id: \.offset) { _, range in
                            let startFraction = min(max(range.start / total, 0), 1)
                            let endFraction = min(max(range.end / total, 0), 1)
                            let rangeWidth = max(0, (endFraction - startFraction) * width)
                            let offset = startFraction * width
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.45))
                                .frame(width: rangeWidth, height: 6)
                                .offset(x: offset)
                        }
                    } else if bufferedTime > 0 {
                        let bufferFraction = min(max(bufferedTime / total, 0), 1)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.45))
                            .frame(width: bufferFraction * width, height: 6)
                    }

                    // Played progress (actual playhead, never faked during buffering)
                    let playedFraction = min(max(current / total, 0), 1)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: playedFraction * width, height: 6)

                    // Actual playhead dot
                    Circle()
                        .fill(Color.white)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(playedFraction * width - 6, width - 12)))

                    // Seek target indicator
                    if pendingSeekTarget != nil {
                        let targetFraction = min(max(target / total, 0), 1)
                        ZStack {
                            Capsule()
                                .fill(BrandPalette.iceBlue)
                                .frame(width: 4, height: 16)
                            Circle()
                                .stroke(BrandPalette.iceBlue, lineWidth: 2)
                                .background(Circle().fill(Color.white))
                                .frame(width: 14, height: 14)
                        }
                        .offset(x: max(0, min(targetFraction * width - 7, width - 14)))
                    }
                }
            }
            .frame(width: 380, height: 18)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .accessibilityIdentifier("player.seekHUD")
    }

    private func formatTime(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let total = Int(value.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func triggerSeeking() {
        let interactionDate = Date()
        seekLastInteractionDate = interactionDate
        withAnimation(.easeInOut(duration: 0.2)) { isSeeking = true }
        seekDismissTask?.cancel()
        seekDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(PlayerSeekHUDPolicy.quietPeriod * 1_000_000_000))
            guard !Task.isCancelled,
                  PlayerSeekHUDPolicy.shouldHide(now: Date(), lastInteraction: seekLastInteractionDate),
                  seekLastInteractionDate == interactionDate else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                isSeeking = false
                pendingSeekTarget = nil
            }
        }
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let coordinator: PlaybackCoordinator

    func makeCoordinator() -> PlaybackCoordinator {
        coordinator
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        coordinator.attachSurface(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        coordinator.attachSurface(view)
    }

    static func dismantleUIView(_ view: UIView, coordinator: PlaybackCoordinator) {
        coordinator.attachSurface(nil)
    }
}

/// Shared queue projection used by both direct file browsing and the matched
/// library. Confirmed metadata wins; unresolved files remain manually playable
/// but are excluded from automatic numbered playback.
enum PlaybackQueueProjection {
    static func sort(_ files: [CloudFile], metadata: [String: ParsedMediaName] = [:]) -> [CloudFile] {
        files.sorted { lhs, rhs in
            let lm = metadata[lhs.fileId], rm = metadata[rhs.fileId]
            let ls = lm?.seasonNumber ?? Int.max, rs = rm?.seasonNumber ?? Int.max
            if ls != rs { return ls < rs }
            let le = lm?.episodeNumber ?? Int.max, re = rm?.episodeNumber ?? Int.max
            if le != re { return le < re }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func automaticFiles(_ files: [CloudFile], metadata: [String: ParsedMediaName]) -> [CloudFile] {
        sort(files.filter { metadata[$0.fileId]?.episodeNumber != nil }, metadata: metadata)
    }

    static func directQueue(files: [CloudFile], selected: CloudFile) -> [CloudFile] {
        let videos = files.filter(\.isVideo)
        let metadata = Dictionary(uniqueKeysWithValues: videos.map { ($0.fileId, FilenameParser.parse($0.name)) })
        return directQueue(files: videos, selected: selected, metadata: metadata)
    }

    static func directQueue(files: [CloudFile], selected: CloudFile, metadata: [String: ParsedMediaName], confirmed: [String: MediaItem] = [:]) -> [CloudFile] {
        let videos = files.filter(\.isVideo)
        guard metadata[selected.fileId]?.episodeNumber != nil else { return [selected] }
        let compatible: [CloudFile]
        if let selectedConfirmed = confirmed[selected.fileId],
           let tmdbID = selectedConfirmed.tmdbId,
           let season = selectedConfirmed.seasonNumber {
            compatible = videos.filter { file in
                guard let item = confirmed[file.fileId] else { return false }
                return item.tmdbId == tmdbID && item.seasonNumber == season && item.episodeNumber != nil
            }
        } else if let selectedMetadata = metadata[selected.fileId],
                  let season = selectedMetadata.seasonNumber,
                  selectedMetadata.mediaType == .series,
                  !MediaAliasResolver.normalizeTitle(selectedMetadata.title).isEmpty {
            let title = MediaAliasResolver.normalizeTitle(selectedMetadata.title)
            compatible = videos.filter {
                guard let candidate = metadata[$0.fileId], candidate.mediaType == .series else { return false }
                return candidate.seasonNumber == season
                    && MediaAliasResolver.normalizeTitle(candidate.title) == title
            }
        } else if let selectedMetadata = metadata[selected.fileId],
                  selectedMetadata.mediaType == .series,
                  !MediaAliasResolver.normalizeTitle(selectedMetadata.title).isEmpty {
            let title = MediaAliasResolver.normalizeTitle(selectedMetadata.title)
            compatible = videos.filter {
                guard let candidate = metadata[$0.fileId], candidate.mediaType == .series else { return false }
                return MediaAliasResolver.normalizeTitle(candidate.title) == title && candidate.seasonNumber == nil
            }
        } else {
            return [selected]
        }
        let ordered = automaticFiles(compatible, metadata: metadata)
        return ordered.isEmpty ? [selected] : ordered
    }
}

// MARK: - Drawer Episode Card with Whole-Card Focus & Thumbnail Preview
private struct DrawerEpisodeCard: View {
    let file: CloudFile
    let parsedMetadata: ParsedMediaName?
    let episodeTitle: String?
    let isCurrent: Bool
    let isPending: Bool
    /// Already-resolved artwork for this card: the episode's TMDB still when
    /// known, otherwise the series backdrop, otherwise nil for a placeholder.
    let artworkURL: URL?
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    private var parsed: ParsedMediaName {
        parsedMetadata ?? FilenameParser.parse(file.name)
    }

    private var cardTitle: String {
        let ep = parsed.episodeNumber
        let series = !parsed.title.isEmpty ? parsed.title : nil

        if let episodeTitle, !episodeTitle.isEmpty {
            if let series, let ep {
                return "\(series) 第 \(ep) 集 · \(episodeTitle)"
            } else if let ep {
                return "第 \(ep) 集 · \(episodeTitle)"
            } else {
                return episodeTitle
            }
        } else if let series, let ep {
            return "\(series) 第 \(ep) 集 · \(file.name)"
        } else if let ep {
            return "第 \(ep) 集 · \(file.name)"
        }
        return file.name
    }

    private var cardBorderColor: Color {
        if isPending { return Color.orange.opacity(0.85) }
        if isCurrent { return BrandPalette.iceBlue }
        if isFocused { return BrandPalette.glassWhite }
        return Color.white.opacity(0.12)
    }

    private var cardBorderWidth: CGFloat {
        if isFocused && isCurrent { return 4.0 }
        if isFocused { return 3.5 }
        if isPending { return 3.0 }
        if isCurrent { return 2.5 }
        return 1.0
    }

    private var infoBackgroundColor: Color {
        if isPending { return Color.orange.opacity(0.16) }
        if isFocused { return Color.black.opacity(0.82) }
        if isCurrent { return BrandPalette.glassWhite.opacity(0.08) }
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
        VStack(alignment: .leading, spacing: 4) {
            Text(cardTitle)
                .font(.subheadline.weight(isFocused ? .bold : .semibold))
                .foregroundStyle(isFocused ? Color.white : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Text(sizeString)
                    .font(.caption2)
                    .foregroundStyle(isFocused ? Color.white.opacity(0.9) : Color.secondary)

                Spacer()

                Text(tagString)
                    .font(.caption2.bold())
                    .foregroundStyle(isCurrent ? BrandPalette.glassWhite : (isFocused ? BrandPalette.glassWhite : BrandPalette.secondaryText))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 360, height: 75, alignment: .leading)
        .background(infoBackgroundColor)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                thumbnailBanner
                    .frame(width: 360, height: 135)
                    .clipped()

                infoArea
            }
            .frame(width: 360, height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(cardBorderColor, lineWidth: cardBorderWidth)
            )
            .shadow(
                color: isCurrent
                    ? BrandPalette.iceBlue.opacity(isFocused ? 0.8 : 0.45)
                    : (isFocused ? BrandPalette.glassWhite.opacity(0.5) : Color.black.opacity(0.35)),
                radius: isFocused ? 14 : 6,
                x: 0,
                y: isFocused ? 6 : 2
            )
            .scaleEffect(DrawerButtonFocusStyle.scale(isFocused: isFocused))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailBanner: some View {
        ZStack(alignment: .center) {
            if let artworkURL {
                AsyncImage(url: artworkURL) { image in
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

            // Center Play Icon (constant size, whole card scales uniformly on focus)
            Image(systemName: isCurrent ? "waveform" : (isPending ? "hourglass" : "play.circle.fill"))
                .font(.system(size: 28))
                .foregroundStyle(isCurrent ? BrandPalette.glassWhite : (isPending ? Color.orange : (isFocused ? BrandPalette.glassWhite : BrandPalette.glassWhite.opacity(0.65))))
                .shadow(color: .black.opacity(0.8), radius: 4)

            // Top Badges
            VStack {
                HStack {
                    if isCurrent {
                        HStack(spacing: 4) {
                            Circle().fill(BrandPalette.iceBlue).frame(width: 6, height: 6)
                            Text("播放中")
                                .font(.caption2.bold())
                                .foregroundStyle(BrandPalette.iceBlue)
                                .accessibilityIdentifier("player.badge.playing")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    } else if isPending {
                        Text("切换中")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
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
                        .foregroundStyle(isFocused ? BrandPalette.glassWhite : BrandPalette.glassWhite.opacity(0.85))
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
                BrandPalette.secondary,
                BrandPalette.deepCharcoal
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
