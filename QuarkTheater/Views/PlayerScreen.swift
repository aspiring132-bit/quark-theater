import SwiftUI
import UIKit

@MainActor
final class PlayerPresentationManager {
    static let notificationName = Notification.Name("QuarkTheater.playerPresentationDidChange")
    private static var activeTokens: Set<AnyHashable> = []
    private static var isDirectlyPresented: Bool = false

    static var isPlayerPresented: Bool {
        isDirectlyPresented || !activeTokens.isEmpty
    }

    static var activeCount: Int {
        isPlayerPresented ? 1 : 0
    }

    static func playerDidAppear(token: AnyHashable? = nil) {
        let wasPresented = isPlayerPresented
        if let token {
            activeTokens.insert(token)
        } else {
            isDirectlyPresented = true
        }
        if !wasPresented && isPlayerPresented {
            postNotification()
        }
    }

    static func playerDidDisappear(token: AnyHashable? = nil) {
        let wasPresented = isPlayerPresented
        if let token {
            activeTokens.remove(token)
        } else {
            isDirectlyPresented = false
            activeTokens.removeAll()
        }
        if wasPresented && !isPlayerPresented {
            postNotification()
        }
    }

    static func resetForTesting() {
        activeTokens.removeAll()
        isDirectlyPresented = false
        postNotification()
    }

    private static func postNotification() {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["isPresented": isPlayerPresented]
        )
    }
}

struct DrawerEpisodeRailMetrics: Equatable {
    static let cardsPerViewport: Int = 3
    static let cardWidth: CGFloat = 370
    static let cardHeight: CGFloat = 220
    static let thumbnailHeight: CGFloat = 138
    static let infoHeight: CGFloat = 82
    static let cardSpacing: CGFloat = 30
    static let horizontalPadding: CGFloat = 35
    static let verticalPadding: CGFloat = 32
    static let railHeight: CGFloat = 320
    static let nextActionWidth: CGFloat = 200
    static let nextActionHeight: CGFloat = 190
    static let focusedScale: CGFloat = 1.05
    static let focusedShadowRadius: CGFloat = 14
    static let focusedShadowYOffset: CGFloat = 6

    static var viewportWidth: CGFloat {
        CGFloat(cardsPerViewport) * cardWidth + CGFloat(cardsPerViewport - 1) * cardSpacing + (2 * horizontalPadding)
    }

    static func totalRailWidth(includingNextAction: Bool) -> CGFloat {
        if includingNextAction {
            return nextActionWidth + cardSpacing + viewportWidth
        } else {
            return viewportWidth
        }
    }

    static func drawerWidth(includingNextAction: Bool) -> CGFloat {
        totalRailWidth(includingNextAction: includingNextAction) + 80
    }

    static var drawerWidth: CGFloat {
        drawerWidth(includingNextAction: true)
    }

    static var scaledCardHeight: CGFloat {
        cardHeight * focusedScale
    }

    static var scaledCardWidth: CGFloat {
        cardWidth * focusedScale
    }

    static var verticalClearance: CGFloat {
        railHeight - scaledCardHeight
    }

    static var verticalExpansionPerSide: CGFloat {
        (scaledCardHeight - cardHeight) / 2
    }

    static var horizontalExpansionPerSide: CGFloat {
        (scaledCardWidth - cardWidth) / 2
    }

    static var topOverflow: CGFloat {
        verticalExpansionPerSide + focusedShadowRadius
    }

    static var bottomOverflow: CGFloat {
        verticalExpansionPerSide + focusedShadowRadius + focusedShadowYOffset
    }

    static var horizontalOverflow: CGFloat {
        horizontalExpansionPerSide + focusedShadowRadius
    }

    static func scale(isFocused: Bool) -> CGFloat {
        isFocused ? focusedScale : 1.0
    }
}

enum PlayerBackDisposition: Equatable, Sendable {
    case closeDrawer
    case dismissPlayer
    case ignore

    var diagnosticDisposition: DiagnosticBackDisposition {
        switch self {
        case .closeDrawer:
            return .closedDrawer
        case .dismissPlayer:
            return .dismissedPlayer
        case .ignore:
            return .ignored
        }
    }
}

struct PlayerBackTransitionState: Equatable, Sendable {
    var isDrawerOpen: Bool
    var lastDrawerCloseDate: Date?
    var lastBackDate: Date?
    var focusedTarget: PlayerFocusTarget?
}

enum PlayerBackTransitionReducer {
    /// Debounce interval to suppress rapid duplicate events (e.g. key-repeat, button down + up bounce).
    static let duplicateDebounceInterval: TimeInterval = 0.50
    /// tvOS can deliver a trailing/repeated Menu event while the drawer is
    /// closing and focus is being restored. Keep that event from being
    /// interpreted as a second, player-dismissal command.
    static let drawerCloseCooldown: TimeInterval = 3.0

    static func evaluate(state: PlayerBackTransitionState, at currentDate: Date) -> PlayerBackDisposition {
        // 1. Rapid duplicate back command within debounce window
        if let lastBack = state.lastBackDate, currentDate.timeIntervalSince(lastBack) < duplicateDebounceInterval {
            return .ignore
        }
        // 2. When drawer is visibly open, back MUST only close the drawer
        if state.isDrawerOpen {
            return .closeDrawer
        }
        // 3. Late duplicate or trailing back event within drawer close cooldown
        if let lastClose = state.lastDrawerCloseDate, currentDate.timeIntervalSince(lastClose) < drawerCloseCooldown {
            return .ignore
        }
        // 4. Focus is in transit (nil) following drawer close or still targeting drawer elements
        if state.focusedTarget == nil {
            return .ignore
        }
        if PlayerInputReducer.isContentLevel(state.focusedTarget) {
            return .ignore
        }
        if case .drawerTab = state.focusedTarget {
            return .ignore
        }
        // 5. Drawer is closed, cooldown has elapsed, and player surface has stable focus: allow dismissal
        return .dismissPlayer
    }
}

enum PlayerCanvasPreviewPolicy {
    static func shouldStartPlayback(isCanvasPreview: Bool) -> Bool { !isCanvasPreview }
    static func shouldShowStaticSurface(isCanvasPreview: Bool) -> Bool { isCanvasPreview }
    static func shouldOpenDrawerInitially(isCanvasPreview: Bool) -> Bool { isCanvasPreview }
}

@MainActor
struct PlayerScreen: View {
    @StateObject private var coordinator: PlaybackCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    static let hintDismissDurationSeconds: Double = 3.0
    @State private var showDrawer: Bool
    @State private var showHintPill = true
    @State private var selectedDrawerTab: DrawerTab = .episodes
    @State private var isSeeking = false
    @State private var pendingSeekTarget: Double?
    @State private var seekCommitTask: Task<Void, Never>?
    @State private var seekDismissTask: Task<Void, Never>?
    @State private var seekState = PlayerRemoteSeekState()
    @State private var seekMultiplier = 1
    @State private var seekLastInteractionDate: Date?
    @State private var lastDrawerCloseTime: Date?
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
    private let onRequestDismiss: (() -> Void)?
    private let isCanvasPreview: Bool

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
         isCanvasPreview: Bool = false,
         onRequestDismiss: (() -> Void)? = nil,
         // Narrow UI-test seam: lets a harness observe the real coordinator's
         // state. Never set in production call sites.
         coordinatorObserver: ((PlaybackCoordinator) -> Void)? = nil) {
        self.diagnostics = diagnostics
        self.backdropURL = backdropURL
        self.episodeMetadataByFileID = episodeMetadataByFileID
        self.seriesTMDBId = seriesTMDBId
        self.artworkProvider = artworkProvider
        self.onRequestDismiss = onRequestDismiss
        self.isCanvasPreview = isCanvasPreview
        _showDrawer = State(initialValue: PlayerCanvasPreviewPolicy.shouldOpenDrawerInitially(isCanvasPreview: isCanvasPreview))
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
            if PlayerCanvasPreviewPolicy.shouldShowStaticSurface(isCanvasPreview: isCanvasPreview) {
                Color.black.ignoresSafeArea()
            } else if coordinator.hasActivePlayer {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                        Button("返回") { requestDismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            // 2. Bottom Drawer Trigger Pill (auto fades after 3s)
            if !showDrawer && (coordinator.hasActivePlayer || isCanvasPreview) {
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
                    .background(Capsule().fill(showHintPill ? Color.white.opacity(0.15) : Color.clear))
                    .opacity(showHintPill ? 1 : 0)
                }
                .buttonStyle(DrawerTriggerButtonStyle())
                .focusEffectDisabled(true)
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
            // Adaptive Network Speed Badge: appears only during real buffering, loading, or seeking (BUG-005)
            if coordinator.isBuffering || coordinator.isLoading || isSeeking {
                speedBadgeView
                    .padding(.top, 40)
                    .padding(.trailing, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .overlay(alignment: .top) {
            if isSeeking {
                seekHUDView
                    .padding(.top, 92)
                    .padding(.horizontal, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // F-001: Focusable Skip Intro / Outro Buttons in bottom-trailing corner
            if !showDrawer {
                let time = coordinator.playbackTime
                let duration = coordinator.playbackDuration
                let markers = coordinator.currentEpisodeMarkers

                if let intro = markers.intro, duration > 0,
                   (time >= intro.startSeconds && time < min(intro.endSeconds, duration)) || coordinator.introSkipStatus != .idle {
                    switch coordinator.introSkipStatus {
                    case .pending:
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                            Text("正在跳过…")
                                .font(.headline.weight(.semibold))
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
                        .padding(.trailing, 60)
                        .padding(.bottom, 60)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    case .failed(let message):
                        Button {
                            coordinator.skipIntro()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.headline)
                                Text(message)
                                    .font(.headline.weight(.semibold))
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.orange.opacity(0.7), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.plain)
                        .focused($focusedTarget, equals: .skipIntro)
                        .accessibilityIdentifier("player.skipIntroButton")
                        .padding(.trailing, 60)
                        .padding(.bottom, 60)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    case .idle:
                        Button {
                            coordinator.skipIntro()
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
                    }
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
                focusedTarget = isCanvasPreview
                    ? .episode(coordinator.committedActiveFileID)
                    : .drawerTrigger
            }
            restartHintDismissTimer()
            if PlayerCanvasPreviewPolicy.shouldStartPlayback(isCanvasPreview: isCanvasPreview) {
                await coordinator.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { coordinator.saveProgress() }
        }
        .onAppear {
            PlayerPresentationManager.playerDidAppear()
        }
        .onDisappear {
            PlayerPresentationManager.playerDidDisappear()
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
        .interactiveDismissDisabled(true)
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
            // Deterministic remote seek reducer:
            // 1. First move uses base configured interval (10/15s) with 1x multiplier.
            // 2. Continuous repeated events from remote hold accelerate across 1x, 2x, 4x, 8x tiers.
            // 3. Multiplier applies per actual remote repeat event, never from timer ticks.
            // 4. Clamps within [0, duration] and commits once after bounded idle timeout (0.45s).
            let now = Date().timeIntervalSinceReferenceDate
            let result = PlayerRemoteSeekReducer.handle(
                state: &seekState,
                event: .playerMove(direction: dir, timestamp: now),
                playbackTime: coordinator.playbackTime,
                duration: coordinator.playbackDuration,
                configuredInterval: interval
            )

            if let nextTarget = result.pendingTarget {
                pendingSeekTarget = nextTarget
            }
            seekMultiplier = result.multiplier

            triggerSeeking()

            seekCommitTask?.cancel()
            seekCommitTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                let timeoutNow = Date().timeIntervalSinceReferenceDate
                let timeoutResult = PlayerRemoteSeekReducer.handle(
                    state: &seekState,
                    event: .idleTimeout(timestamp: timeoutNow),
                    playbackTime: coordinator.playbackTime,
                    duration: coordinator.playbackDuration,
                    configuredInterval: interval
                )
                if timeoutResult.shouldCommit, let target = timeoutResult.commitTarget {
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
            let currentFileID = coordinator.committedActiveFileID
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
        selectedDrawerTab = .episodes
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showDrawer = true
            showHintPill = false
        }
        loadEpisodeArtwork()
        // Give a brief moment for views to appear, then set focus
        let currentID = coordinator.committedActiveFileID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedTarget = .episode(currentID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard showDrawer, selectedDrawerTab == .episodes else { return }
            focusedTarget = .episode(currentID)
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
        lastDrawerCloseTime = Date()
        selectedDrawerTab = .episodes
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
        let transitionState = PlayerBackTransitionState(
            isDrawerOpen: showDrawer,
            lastDrawerCloseDate: lastDrawerCloseTime,
            lastBackDate: lastBackDate,
            focusedTarget: focusedTarget
        )
        let disposition = PlayerBackTransitionReducer.evaluate(state: transitionState, at: now)

        var metadata: [DiagnosticMetadata] = [
            .backDisposition(disposition.diagnosticDisposition)
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
        print("[PlayerScreen] handleBackCommand: disposition=\(disposition), isDrawerOpen=\(showDrawer), focusedTarget=\(String(describing: focusedTarget)), playingID=\(playingID)")

        switch disposition {
        case .closeDrawer:
            lastBackDate = now
            closeDrawer()
        case .ignore:
            break
        case .dismissPlayer:
            lastBackDate = now
            requestDismiss()
        }
    }

    private func requestDismiss() {
        if let onRequestDismiss {
            onRequestDismiss()
        } else {
            dismiss()
        }
    }

    private func restartHintDismissTimer() {
        hintDismissTask?.cancel()
        hintDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.hintDismissDurationSeconds * 1_000_000_000))
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
            .frame(minHeight: 180, maxHeight: DrawerEpisodeRailMetrics.railHeight)
            .padding(.top, 8)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: DrawerEpisodeRailMetrics.drawerWidth(includingNextAction: coordinator.canPlayNext), maxHeight: 520, alignment: .bottom)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
        .focusSection()
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
        HStack(spacing: DrawerEpisodeRailMetrics.cardSpacing) {
            if coordinator.canPlayNext {
                nextEpisodeButton
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DrawerEpisodeRailMetrics.cardSpacing) {
                        ForEach(Array(coordinator.playlistQueue.enumerated()), id: \.element.fileId) { index, file in
                            let isCurrent = coordinator.isEpisodePlaying(fileID: file.fileId) ||
                                (isCanvasPreview && file.fileId == coordinator.committedActiveFileID)
                            let isPending = coordinator.isEpisodePending(fileID: file.fileId)

                            DrawerEpisodeCard(
                                file: file,
                                parsedMetadata: episodeMetadataByFileID[file.fileId],
                                episodeTitle: episodeTitleByFileID[file.fileId],
                                isCurrent: isCurrent,
                                isPending: isPending,
                                // Fallback chain: episode still → series backdrop → placeholder.
                                artworkURL: stillURLByFileID[file.fileId] ?? backdropURL,
                                action: {
                                    guard !isCanvasPreview else { return }
                                    coordinator.playFile(
                                        file,
                                        selectionOrdinal: index,
                                        episodeNumber: episodeMetadataByFileID[file.fileId]?.episodeNumber
                                    )
                                    closeDrawer()
                                }
                            )
                            .id(PlayerFocusTarget.episode(file.fileId))
                            .focused($focusedTarget, equals: .episode(file.fileId))
                            .accessibilityIdentifier("player.episodeCard.\(index)")
                        }
                    }
                    .padding(.horizontal, DrawerEpisodeRailMetrics.horizontalPadding)
                    // The focused card scales to 1.05. Keep generous breathing room so
                    // its top episode/playing badges stay clear of the ScrollView's clipping bounds.
                    .padding(.vertical, DrawerEpisodeRailMetrics.verticalPadding)
                }
                .scrollClipDisabled()
                .frame(width: DrawerEpisodeRailMetrics.viewportWidth, height: DrawerEpisodeRailMetrics.railHeight)
                .accessibilityIdentifier("player.episodeScroll")
                .onAppear {
                    let targetID = coordinator.committedActiveFileID
                    proxy.scrollTo(PlayerFocusTarget.episode(targetID), anchor: .center)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard showDrawer, selectedDrawerTab == .episodes else { return }
                        focusedTarget = .episode(targetID)
                    }
                }
                .onChange(of: focusedTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
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
        let names = coordinator.audioTrackNames
        if names.isEmpty {
            Text("无可用音轨")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 44)
                .padding(.vertical, 24)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
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
                .padding(.horizontal, 44)
                .padding(.vertical, 16)
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
        let text = PlayerSpeedBadgePolicy.badgeText(
            isBuffering: coordinator.isBuffering,
            isLoading: coordinator.isLoading,
            isSeeking: isSeeking,
            speedText: speed
        )

        if let text {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.fill")
                    .foregroundStyle(BrandPalette.glassWhite)
                if coordinator.isBuffering || coordinator.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                }
                Text(text)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
        }
    }

    @ViewBuilder
    private var seekHUDView: some View {
        let duration = coordinator.playbackDuration
        let current = coordinator.playbackTime
        let bufferedTime = coordinator.bufferedTime
        let bufferedRanges = coordinator.bufferedRanges

        VStack(alignment: .leading, spacing: 12) {
            // Header Row: Left seek target/diff/multiplier, Right played & total duration
            HStack(alignment: .firstTextBaseline) {
                if let pending = pendingSeekTarget {
                    let diffStr = PlayerTimeFormatter.formatTargetDiff(pending: pending, current: current)
                    HStack(spacing: 8) {
                        Text("跳转目标: \(PlayerTimeFormatter.formatPlaybackTime(pending, duration: duration))")
                            .font(.headline.weight(.bold).monospacedDigit())
                            .foregroundStyle(BrandPalette.iceBlue)
                        Text("(\(diffStr))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(BrandPalette.iceBlue.opacity(0.85))
                        if seekMultiplier > 1 {
                            Text("\(seekMultiplier)x")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(BrandPalette.iceBlue.opacity(0.8)))
                        }
                    }
                }

                Spacer(minLength: 24)

                HStack(spacing: 6) {
                    Text("已播放: \(PlayerTimeFormatter.formatCurrentTime(current, duration: duration))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white)
                    Text("/ 总时长: \(PlayerTimeFormatter.formatDuration(duration))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Scrubber Bar with 3 distinctly styled layers (adapts to full content width)
            GeometryReader { geo in
                let width = geo.size.width
                let playedFraction = PlayerScrubberGeometryPolicy.playedFraction(current: current, duration: duration)
                let targetFrac = PlayerScrubberGeometryPolicy.targetFraction(target: pendingSeekTarget, duration: duration)
                let bufferSegments = PlayerScrubberGeometryPolicy.bufferedFractions(ranges: bufferedRanges, duration: duration)

                ZStack(alignment: .leading) {
                    // Layer 1: Remainder / Total duration track (Deep dark slate with subtle rim)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .frame(height: 8)

                    // Layer 2: Buffered Ranges (HLS segments - Cool Cyan/Ice-Blue)
                    if !bufferSegments.isEmpty {
                        ForEach(Array(bufferSegments.enumerated()), id: \.offset) { _, seg in
                            let rangeWidth = max(2, (seg.endFraction - seg.startFraction) * width)
                            let offset = seg.startFraction * width
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.35, green: 0.75, blue: 0.95).opacity(0.75))
                                .frame(width: rangeWidth, height: 8)
                                .offset(x: offset)
                        }
                    } else if bufferedTime > 0, duration > 0 {
                        let singleFrac = min(max(bufferedTime / duration, 0), 1)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 0.35, green: 0.75, blue: 0.95).opacity(0.75))
                            .frame(width: singleFrac * width, height: 8)
                    }

                    // Layer 3: Played progress (Solid Bright White)
                    if playedFraction > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                            .frame(width: playedFraction * width, height: 8)
                    }

                    // Layer 4: Playhead Dot (White circle with drop shadow)
                    if duration > 0 {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                            .offset(x: max(0, min(playedFraction * width - 7, width - 14)))
                    }

                    // Layer 5: Seek Target Cursor (Glowing Accent Marker)
                    if let targetFrac {
                        ZStack {
                            Capsule()
                                .fill(BrandPalette.iceBlue)
                                .frame(width: 4, height: 20)
                            Circle()
                                .stroke(BrandPalette.iceBlue, lineWidth: 2.5)
                                .background(Circle().fill(Color.white))
                                .frame(width: 14, height: 14)
                                .shadow(color: BrandPalette.iceGlow, radius: 6)
                        }
                        .offset(x: max(0, min(targetFrac * width - 7, width - 14)))
                    }
                }
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)
        .accessibilityIdentifier("player.seekHUD")
    }

    private func formatTime(_ value: Double) -> String {
        PlayerTimeFormatter.formatPlaybackTime(value, duration: coordinator.playbackDuration)
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
    var onExit: (() -> Void)? = nil

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
                .font(.subheadline.weight(.semibold))
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
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(width: DrawerEpisodeRailMetrics.cardWidth, height: DrawerEpisodeRailMetrics.infoHeight, alignment: .leading)
        .background(infoBackgroundColor)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                thumbnailBanner
                    .frame(width: DrawerEpisodeRailMetrics.cardWidth, height: DrawerEpisodeRailMetrics.thumbnailHeight)
                    .clipped()

                infoArea
            }
            .frame(width: DrawerEpisodeRailMetrics.cardWidth, height: DrawerEpisodeRailMetrics.cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(cardBorderColor, lineWidth: cardBorderWidth)
            )
            .shadow(
                color: isCurrent
                    ? BrandPalette.iceBlue.opacity(isFocused ? 0.8 : 0.45)
                    : (isFocused ? BrandPalette.glassWhite.opacity(0.5) : Color.black.opacity(0.35)),
                radius: isFocused ? DrawerEpisodeRailMetrics.focusedShadowRadius : 6,
                x: 0,
                y: isFocused ? DrawerEpisodeRailMetrics.focusedShadowYOffset : 2
            )
            .scaleEffect(DrawerEpisodeRailMetrics.scale(isFocused: isFocused))
            .zIndex(isFocused ? 1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(true)
        .zIndex(isFocused ? 1 : 0)
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
                HStack(spacing: 6) {
                    if let ep = parsed.episodeNumber {
                        Text("第 \(ep) 集")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

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
                    }

                    Spacer()

                    Text(file.fileExtension.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(isFocused ? BrandPalette.glassWhite : BrandPalette.glassWhite.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

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

struct DrawerTriggerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

enum PlayerTimeFormatter {
    static func formatDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    static func formatCurrentTime(_ time: TimeInterval, duration: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "--:--" }
        if duration <= 0 && time == 0 {
            return "--:--"
        }
        return formatPlaybackTime(time, duration: duration)
    }

    static func formatPlaybackTime(_ time: TimeInterval, duration: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "--:--" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 || duration >= 3600 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    static func formatTargetDiff(pending: TimeInterval, current: TimeInterval) -> String {
        let diff = pending - current
        let rounded = Int(diff.rounded())
        return rounded >= 0 ? "+\(rounded)s" : "\(rounded)s"
    }
}

struct ScrubberSegment: Equatable, Sendable {
    let startFraction: Double
    let endFraction: Double
}

enum PlayerScrubberGeometryPolicy {
    static func playedFraction(current: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, current.isFinite, current >= 0 else { return 0 }
        return min(max(current / duration, 0), 1)
    }

    static func targetFraction(target: TimeInterval?, duration: TimeInterval) -> Double? {
        guard let target, duration > 0, target.isFinite, target >= 0 else { return nil }
        return min(max(target / duration, 0), 1)
    }

    static func bufferedFractions(ranges: [PlaybackTimeRange], duration: TimeInterval) -> [ScrubberSegment] {
        guard duration > 0 else { return [] }
        return ranges.compactMap { range in
            let s = min(max(range.start / duration, 0), 1)
            let e = min(max(range.end / duration, 0), 1)
            guard e > s else { return nil }
            return ScrubberSegment(startFraction: s, endFraction: e)
        }
    }
}

enum PlayerSpeedBadgePolicy {
    static func badgeText(
        isBuffering: Bool,
        isLoading: Bool,
        isSeeking: Bool = false,
        speedText: String
    ) -> String? {
        if isBuffering {
            return speedText.isEmpty ? "缓冲中…" : "缓冲中 · \(speedText)"
        }
        if isLoading {
            return speedText.isEmpty ? "正在加载…" : "正在加载 · \(speedText)"
        }
        if isSeeking {
            return speedText.isEmpty ? "正在跳转…" : speedText
        }
        return nil
    }
}
