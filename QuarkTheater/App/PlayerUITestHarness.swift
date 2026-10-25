import AVFoundation
import SwiftUI

// MARK: - UI Test Launch Seam (--uitest-player)
//
// This file implements the deterministic player entry point used by
// QuarkTheaterUITests. It is only reached when the app is launched with the
// `--uitest-player` argument; the normal production launch path is unchanged.
// The fixture never contacts Quark, TMDB, or any network endpoint: playback
// resolves to a locally generated black video file.

/// Deterministic playback client for UI tests. Only `playbackResource` and
/// `restoreSession` are implemented; every other entry point throws
/// `QuarkError.mockOnly` so an accidental network-adjacent path fails loudly.
@MainActor
final class UITestPlaybackClient: QuarkClient {
    private let testAccount = Account(
        accountId: "uitest-account",
        displayName: "UI Test",
        authenticationState: .authenticated
    )

    func restoreSession() async throws -> Account? { testAccount }
    func beginQRCodeLogin() async throws -> QRLoginChallenge { throw QuarkError.mockOnly }
    func pollQRCodeLogin(_ challenge: QRLoginChallenge) async throws -> QRLoginState { throw QuarkError.mockOnly }
    func cancelQRCodeLogin() {}
    func listFiles(parentID: String, page: Int, pageSize: Int) async throws -> CloudFilePage { throw QuarkError.mockOnly }
    func searchFiles(query: String, page: Int, pageSize: Int) async throws -> CloudFilePage { throw QuarkError.mockOnly }

    func playbackResource(fileID: String, correlationID: DiagnosticCorrelationID?) async throws -> PlaybackResource {
        let url = try await UITestVideoFactory.shared.videoURL()
        return PlaybackResource(fileID: fileID, url: url, cookies: [], requiredHTTPHeaders: [:], expiresAt: nil)
    }

    func logout() async throws {}
}

/// Generates a tiny local H.264 clip once per install so VLC has a real,
/// fully offline media source. Every frame is a keyframe
/// (`maxKeyFrameInterval = 1`) so seek targets land exactly where the reducer
/// asked, which is what makes the 10/15-second assertions deterministic.
actor UITestVideoFactory {
    static let shared = UITestVideoFactory()

    private var cachedURL: URL?
    private var inFlight: Task<URL, Error>?

    func videoURL() async throws -> URL {
        if let cachedURL { return cachedURL }
        if let inFlight { return try await inFlight.value }
        let task = Task<URL, Error> { try await Self.generate() }
        inFlight = task
        do {
            let url = try await task.value
            cachedURL = url
            inFlight = nil
            return url
        } catch {
            inFlight = nil
            throw error
        }
    }

    private enum FactoryError: Error, LocalizedError {
        case cannotAddInput
        case writerFailed(String)
        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "AVAssetWriter refused the video input."
            case .writerFailed(let reason): return "AVAssetWriter failed: \(reason)"
            }
        }
    }

    private static func generate(duration: Double = 180, fps: Int32 = 10) async throws -> URL {
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarktheater-uitest-sample.mp4")
        if FileManager.default.fileExists(atPath: finalURL.path) { return finalURL }
        let partialURL = finalURL.deletingPathExtension().appendingPathExtension("partial.mp4")
        try? FileManager.default.removeItem(at: partialURL)

        let writer = try AVAssetWriter(url: partialURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 360,
            // Every frame a keyframe: seek targets land exactly where the
            // reducer asked, keeping the 10/15-second assertions exact.
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360
        ])
        guard writer.canAdd(input) else { throw FactoryError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw FactoryError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int64(duration * Double(fps))
        var frame: Int64 = 0
        while frame < totalFrames {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            autoreleasepool {
                guard let pool = adaptor.pixelBufferPool else { return }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                      let pixelBuffer else { return }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: frame, timescale: fps))
            }
            frame += 1
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FactoryError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        return finalURL
    }
}

/// Polls the real `PlaybackCoordinator` and publishes observable playback
/// state for the test overlay. Read-only: it never drives the player.
@MainActor
final class UITestPlayerProbe: ObservableObject {
    @Published private(set) var playState = "loading"
    @Published private(set) var timeText = "0.00"
    @Published private(set) var durationText = "0.00"

    private weak var coordinator: PlaybackCoordinator?
    private var timer: Timer?

    func attach(_ coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let coordinator else {
            playState = "loading"
            return
        }
        playState = coordinator.isPlaying ? "playing" : "paused"
        timeText = String(format: "%.2f", coordinator.playbackTime)
        durationText = String(format: "%.2f", coordinator.playbackDuration)
    }
}

/// The UI-test entry view: the real `PlayerScreen` with a deterministic
/// three-episode queue, plus a small non-interactive state readout. The
/// overlay only reports state; assertions about focus and actions run against
/// the production controls via their accessibility identifiers.
@MainActor
struct PlayerUITestHarness: View {
    @StateObject private var probe = UITestPlayerProbe()

    private let client = UITestPlaybackClient()
    private let history: HistoryRepository
    private let diagnostics = Diagnostics()
    private let files: [CloudFile]
    private let metadataByFileID: [String: ParsedMediaName]

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarktheater-uitest-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A failing test database must fail loudly here, not degrade playback.
        history = try! HistoryRepository(url: directory.appendingPathComponent("watch-history.sqlite"))
        files = (1...3).map { episode in
            CloudFile(fileId: "uitest-ep\(episode)", parentId: "uitest",
                      name: "UITest.Series.S01E0\(episode).mp4",
                      size: 1_024_000, fileExtension: "mp4", modifiedAt: nil, isDirectory: false)
        }
        metadataByFileID = Dictionary(uniqueKeysWithValues: files.enumerated().map { index, file in
            (file.fileId, ParsedMediaName(title: "UITest Series", mediaType: .series,
                                          seasonNumber: 1, episodeNumber: index + 1))
        })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerScreen(
                client: client,
                accountID: "uitest-account",
                file: files[0],
                queue: files,
                automaticallyPlayNext: false,
                history: history,
                diagnostics: diagnostics,
                episodeMetadataByFileID: metadataByFileID,
                coordinatorObserver: { coordinator in probe.attach(coordinator) }
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(probe.playState)
                    .accessibilityIdentifier("player.playPauseState")
                Text(probe.timeText)
                    .accessibilityIdentifier("player.timeText")
                Text(probe.durationText)
                    .accessibilityIdentifier("player.durationText")
            }
            .font(.system(size: 16, design: .monospaced))
            .foregroundStyle(.white.opacity(0.65))
            .padding(8)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(.top, 28)
            .padding(.leading, 44)
            .allowsHitTesting(false)
        }
    }
}
