import Foundation

struct PlaybackTrack: Equatable, Identifiable {
    enum Kind: Equatable { case audio, subtitle }

    let id: Int
    let kind: Kind
    let name: String
    let languageCode: String?
    let isDisabled: Bool
}

enum PlaybackEngineState: Equatable {
    case idle, loading, ready, buffering, playing, paused, ended, failed
}

struct PlaybackBufferingPolicy: Equatable {
    struct State: Equatable {
        var lastPlaybackTime: TimeInterval?
        var lastProgressAt: Date?
        var generation: Int

        static func reset(for generation: Int) -> State {
            State(lastPlaybackTime: nil, lastProgressAt: nil, generation: generation)
        }
    }

    var graceWindow: TimeInterval = 1.0
    var minimumProgress: TimeInterval = 0.05

    func updating(currentTime: TimeInterval, state: PlaybackEngineState, generation: Int, now: Date, previousState: State?) -> State {
        guard let previous = previousState, previous.generation == generation else {
            let hasValidTime = currentTime.isFinite && currentTime >= 0
            return State(
                lastPlaybackTime: hasValidTime ? currentTime : nil,
                lastProgressAt: nil,
                generation: generation
            )
        }

        var nextState = previous
        if currentTime.isFinite && currentTime >= 0 {
            if let lastTime = previous.lastPlaybackTime {
                if currentTime - lastTime >= minimumProgress {
                    nextState.lastProgressAt = now
                    nextState.lastPlaybackTime = currentTime
                }
            } else {
                nextState.lastPlaybackTime = currentTime
            }
        }
        return nextState
    }

    func shouldDisplayBuffering(engineState: PlaybackEngineState, policyState: State?, now: Date) -> Bool {
        guard engineState == .buffering else { return false }
        guard let lastProgressAt = policyState?.lastProgressAt else { return true }
        let elapsedSinceProgress = now.timeIntervalSince(lastProgressAt)
        if elapsedSinceProgress >= 0 && elapsedSinceProgress <= graceWindow {
            return false
        }
        return true
    }
}

struct PlaybackTimeRange: Equatable, Hashable {
    let start: TimeInterval
    let end: TimeInterval
}

struct PlaybackSegmentRange: Codable, Equatable, Hashable {
    let startSeconds: Double
    let endSeconds: Double
}

struct ResolvedEpisodeMarkers: Equatable {
    let intro: PlaybackSegmentRange?
    let outro: PlaybackSegmentRange?

    static let empty = ResolvedEpisodeMarkers(intro: nil, outro: nil)
}

struct PlaybackSnapshot: Equatable {
    static let zero = PlaybackSnapshot.idle()
    let generation: Int
    let state: PlaybackEngineState
    let currentTime: TimeInterval
    let duration: TimeInterval
    let bufferedTime: TimeInterval
    let networkRate: Double
    let hasVideoOutput: Bool
    let bufferedRanges: [PlaybackTimeRange]

    init(generation: Int, state: PlaybackEngineState, currentTime: TimeInterval,
         duration: TimeInterval, bufferedTime: TimeInterval, networkRate: Double,
         hasVideoOutput: Bool, bufferedRanges: [PlaybackTimeRange] = []) {
        self.generation = generation
        self.state = state
        self.currentTime = currentTime
        self.duration = duration
        self.bufferedTime = bufferedTime
        self.networkRate = networkRate
        self.hasVideoOutput = hasVideoOutput
        self.bufferedRanges = bufferedRanges
    }

    static func idle(generation: Int = 0) -> PlaybackSnapshot {
        PlaybackSnapshot(generation: generation, state: .idle, currentTime: 0,
                         duration: 0, bufferedTime: 0, networkRate: 0,
                         hasVideoOutput: false, bufferedRanges: [])
    }
}

struct PlaybackDiagnosticSnapshot: Equatable {
    let generation: Int
    let mediaIdentifier: String
    let state: PlaybackEngineState
    let hasVideoOutput: Bool
    let decodedAudioBuffers: Int
    let lostAudioBuffers: Int
    let decodedVideoFrames: Int
    let lostVideoFrames: Int

    init(generation: Int, mediaIdentifier: String, state: PlaybackEngineState,
         hasVideoOutput: Bool, decodedAudioBuffers: Int, lostAudioBuffers: Int,
         decodedVideoFrames: Int, lostVideoFrames: Int) {
        self.generation = generation
        self.mediaIdentifier = Self.redactedMediaIdentifier(mediaIdentifier)
        self.state = state
        self.hasVideoOutput = hasVideoOutput
        self.decodedAudioBuffers = decodedAudioBuffers
        self.lostAudioBuffers = lostAudioBuffers
        self.decodedVideoFrames = decodedVideoFrames
        self.lostVideoFrames = lostVideoFrames
    }

    /// Diagnostics must never retain signed URLs or request credentials.
    static func redactedMediaIdentifier(_ value: String) -> String {
        guard let components = URLComponents(string: value), components.scheme != nil else {
            return value.split(separator: "?").first.map(String.init) ?? value
        }
        var sanitized = components
        sanitized.query = nil
        sanitized.fragment = nil
        return sanitized.string ?? value.split(separator: "?").first.map(String.init) ?? value
    }
}

enum PlaybackEngineEvent {
    case stateChanged(PlaybackSnapshot)
    case tracksChanged(generation: Int, audio: [PlaybackTrack], subtitles: [PlaybackTrack],
                       selectedAudioID: Int?, selectedSubtitleID: Int?)
    case ready(PlaybackSnapshot)
    case ended(PlaybackSnapshot)
    case failed(error: Error, snapshot: PlaybackSnapshot)
    case diagnostic(PlaybackDiagnosticSnapshot)

    var generation: Int {
        switch self {
        case .stateChanged(let snapshot), .ready(let snapshot), .ended(let snapshot): return snapshot.generation
        case .tracksChanged(let generation, _, _, _, _): return generation
        case .failed(_, let snapshot): return snapshot.generation
        case .diagnostic(let snapshot): return snapshot.generation
        }
    }
}
