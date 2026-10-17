import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var audioOptions: [AVMediaSelectionOption] = []
    @Published private(set) var subtitleOptions: [AVMediaSelectionOption] = []
    private let client: QuarkClient
    private let accountID: String
    private var currentFile: CloudFile
    private let queue: [CloudFile]
    private let automaticallyPlayNext: Bool
    private let history: HistoryRepository
    private let diagnostics: Diagnostics
    private let retryPolicy = RetryPolicy(maximumRetries: 2, baseDelay: 1)
    private var periodicObserver: Any?
    private var itemObservers: [NSObjectProtocol] = []
    private var itemStatusObserver: NSKeyValueObservation?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var retryTask: Task<Void, Never>?
    private var retriesUsed = 0
    private var restoredPosition: Double = 0
    private var generation = 0

    init(client: QuarkClient, accountID: String, file: CloudFile, queue: [CloudFile] = [],
         automaticallyPlayNext: Bool = false, history: HistoryRepository, diagnostics: Diagnostics) {
        self.client = client
        self.accountID = accountID
        self.currentFile = file
        self.queue = queue.isEmpty ? [file] : queue
        self.automaticallyPlayNext = automaticallyPlayNext
        self.history = history
        self.diagnostics = diagnostics
    }

    func start() async {
        guard !isLoading, player == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            restoredPosition = try history.history(accountID: accountID, fileID: currentFile.fileId)?.positionSeconds ?? 0
            try await resolveAndPlay(at: restoredPosition)
        } catch is CancellationError { return }
        catch { report(error) }
    }

    func saveProgress() {
        guard let player else { return }
        let position = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        let duration = max(0, player.currentItem?.duration.seconds.isFinite == true ? player.currentItem!.duration.seconds : 0)
        let completed = duration > 0 && position >= duration * 0.95
        let record = WatchHistory(accountId: accountID, fileId: currentFile.fileId,
            positionSeconds: completed ? duration : position, durationSeconds: duration,
            lastWatchedAt: Date(), completed: completed)
        do { try history.save(record) }
        catch { diagnostics.record("观看进度保存失败：\(error.localizedDescription)") }
    }

    func retry() {
        retryTask?.cancel()
        retriesUsed = 0
        retryTask = Task { await startRetryLoop() }
    }

    @Published private(set) var selectedAudioIndex: Int?
    @Published private(set) var selectedSubtitleIndex: Int?

    var currentPlayingFile: CloudFile { currentFile }
    var playlistQueue: [CloudFile] { queue }

    func selectAudio(_ index: Int) {
        guard audioOptions.indices.contains(index), let audioGroup else { return }
        selectedAudioIndex = index
        player?.currentItem?.select(audioOptions[index], in: audioGroup)
    }

    func selectSubtitle(_ index: Int?) {
        guard let subtitleGroup else { return }
        selectedSubtitleIndex = index
        if let index, subtitleOptions.indices.contains(index) {
            player?.currentItem?.select(subtitleOptions[index], in: subtitleGroup)
        } else {
            player?.currentItem?.select(nil, in: subtitleGroup)
        }
    }

    var canPlayNext: Bool {
        guard let index = queue.firstIndex(where: { $0.fileId == currentFile.fileId }) else { return false }
        return queue.indices.contains(index + 1)
    }

    func playFile(_ targetFile: CloudFile) {
        guard targetFile.fileId != currentFile.fileId else { return }
        saveProgress()
        retryTask?.cancel()
        detachObservers()
        player?.pause()
        generation &+= 1
        currentFile = targetFile
        restoredPosition = 0
        retriesUsed = 0
        message = nil
        selectedAudioIndex = nil
        selectedSubtitleIndex = nil
        retryTask = Task {
            do { try await resolveAndPlay(at: 0) }
            catch is CancellationError { return }
            catch { report(error) }
        }
    }

    func playNext() {
        guard let index = queue.firstIndex(where: { $0.fileId == currentFile.fileId }),
              queue.indices.contains(index + 1) else { return }
        playFile(queue[index + 1])
    }

    func stop() {
        generation &+= 1
        retryTask?.cancel()
        saveProgress()
        if let periodicObserver, let player { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        player?.pause()
        player = nil
    }

    private func resolveAndPlay(at position: Double) async throws {
        let requestGeneration = generation
        let requestedFile = currentFile
        let resource = try await client.playbackResource(fileID: requestedFile.fileId)
        guard requestGeneration == generation, requestedFile.fileId == currentFile.fileId,
              !Task.isCancelled else { throw CancellationError() }
        guard resource.url.scheme?.lowercased() == "https" else {
            throw QuarkError.unsupportedPlayback("仅允许 HTTPS 播放地址。")
        }
        let headers = resource.requiredHTTPHeaders
        let unsupported = headers.keys.filter { !["user-agent", "cookie"].contains($0.lowercased()) }
        // AVURLAsset has no supported general-purpose Origin/Referer header option.
        // Do not rely on private/undocumented AVURLAssetHTTPHeaderFieldsKey.
        if !unsupported.isEmpty {
            diagnostics.record("AVPlayer 不能通过公开选项设置所需请求头：\(unsupported.sorted().joined(separator: ", "))")
        }
        let options: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: headers.first(where: { $0.key.lowercased() == "user-agent" })?.value ?? "",
            AVURLAssetHTTPCookiesKey: PlaybackProbe.applicableCookies(resource.cookies, url: resource.url)
        ]
        let asset = AVURLAsset(url: resource.url, options: options)
        let item = AVPlayerItem(asset: asset)
        let next = AVPlayer(playerItem: item)
        detachObservers()
        attachProgressObserver(to: next)
        player?.pause()
        player = next
        audioOptions = []; subtitleOptions = []; audioGroup = nil; subtitleGroup = nil
        Task { await loadMediaOptions(asset: asset, for: item, generation: requestGeneration) }
        if position > 0 {
            // seek(to:) is async in tvOS 26+ SDK; dispatch to avoid blocking the calling context.
            Task { await next.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        }
        next.play()
        diagnostics.record("开始播放请求：\(requestedFile.name)")
    }

    private func loadMediaOptions(asset: AVURLAsset, for item: AVPlayerItem, generation: Int) async {
        do {
            let audio = try await asset.loadMediaSelectionGroup(for: .audible)
            let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
            guard generation == self.generation, player?.currentItem === item else { return }
            audioGroup = audio; subtitleGroup = subtitles
            audioOptions = audio?.options ?? []
            subtitleOptions = subtitles?.options ?? []
            if let audio, let currentAudio = item.currentMediaSelection.selectedMediaOption(in: audio) {
                selectedAudioIndex = audio.options.firstIndex(of: currentAudio)
            }
            if let subtitles, let currentSub = item.currentMediaSelection.selectedMediaOption(in: subtitles) {
                selectedSubtitleIndex = subtitles.options.firstIndex(of: currentSub)
            }
        } catch {
            if !(error is CancellationError) {
                diagnostics.record("音轨/字幕信息暂不可用（系统错误码 \((error as NSError).code)）")
            }
        }
    }

    private func attachProgressObserver(to player: AVPlayer) {
        if let item = player.currentItem {
            itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed, let error = item.error else { return }
                Task { @MainActor in
                    guard self?.player?.currentItem === item else { return }
                    self?.handlePlaybackFailure(error)
                }
            }
        }
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 15, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in Task { @MainActor in
            guard self?.player === player else { return }
            self?.saveProgress()
        } }
        itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in
                    guard self?.player?.currentItem === player.currentItem else { return }
                    self?.handlePlaybackFailure(error ?? QuarkError.invalidResponse("播放失败"))
                }
            })
        itemObservers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] note in
                guard let item = note.object as? AVPlayerItem else { return }
                Task { @MainActor in
                    guard self?.player?.currentItem === item else { return }
                    self?.playbackEnded()
                }
            })
    }

    private func detachObservers() {
        if let periodicObserver, let player { player.removeTimeObserver(periodicObserver) }
        periodicObserver = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
    }

    private func handlePlaybackFailure(_ error: Error) {
        saveProgress()
        guard let delay = retryPolicy.delay(for: error, retriesUsed: retriesUsed) else {
            report(error)
            return
        }
        retriesUsed += 1
        message = "播放中断，正在重新获取地址并重试（\(retriesUsed)/2）…"
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do { try await resolveAndPlay(at: player?.currentTime().seconds ?? restoredPosition) }
            catch is CancellationError { return }
            catch { report(error) }
        }
    }

    private func playbackEnded() {
        saveProgress()
        if automaticallyPlayNext { playNext() }
        else if canPlayNext { message = "本集已播放完成，可选择播放下一集。" }
    }

    private func startRetryLoop() async {
        isLoading = true
        defer { isLoading = false }
        do { try await resolveAndPlay(at: player?.currentTime().seconds ?? restoredPosition); message = nil }
        catch is CancellationError { return }
        catch { report(error) }
    }

    private func report(_ error: Error) {
        let safeMessage: String
        if let quarkError = error as? QuarkError { safeMessage = quarkError.localizedDescription }
        else if let urlError = error as? URLError { safeMessage = "网络播放错误（\(urlError.code.rawValue)）" }
        else { safeMessage = "播放失败（系统错误码 \((error as NSError).code)）" }
        message = safeMessage
        diagnostics.record("播放失败：\(safeMessage)")
    }
}
