import Foundation

/// Events consumed by the deterministic remote seek state machine.
enum PlayerRemoteSeekEvent: Equatable {
    case playerMove(direction: PlayerSeekDirection, timestamp: TimeInterval)
    case idleTimeout(timestamp: TimeInterval)
    case heartbeatTick(timestamp: TimeInterval)
    case reset
}

/// State tracking an ongoing remote seek session.
struct PlayerRemoteSeekState: Equatable {
    var activeDirection: PlayerSeekDirection? = nil
    var sessionStartTime: TimeInterval? = nil
    var lastEventTime: TimeInterval? = nil
    var repeatCount: Int = 0
    var pendingTarget: Double? = nil
    var isCommitted: Bool = false
}

/// Evaluation result from applying a remote seek event.
struct PlayerRemoteSeekResult: Equatable {
    var pendingTarget: Double?
    var multiplier: Int
    var effectiveInterval: Int
    var shouldCommit: Bool
    var commitTarget: Double?
}

/// Acceleration policy for Siri Remote repeated directional presses.
/// - Tier 1 (0.0s – 1.0s or repeats < 2): 1x
/// - Tier 2 (1.0s – 2.5s or repeats 2..3): 2x
/// - Tier 3 (2.5s – 5.0s or repeats 4..7): 4x
/// - Tier 4 (>= 5.0s or repeats >= 8): 8x
enum PlayerSeekAccelerationPolicy {
    static let tier1Elapsed: TimeInterval = 1.0
    static let tier2Elapsed: TimeInterval = 2.5
    static let tier3Elapsed: TimeInterval = 5.0

    static func multiplier(elapsed: TimeInterval) -> Int {
        if elapsed >= tier3Elapsed {
            return 8
        } else if elapsed >= tier2Elapsed {
            return 4
        } else if elapsed >= tier1Elapsed {
            return 2
        } else {
            return 1
        }
    }

    static func effectiveInterval(base: Int, multiplier: Int) -> Int {
        let normalizedBase = PlayerSeekMath.normalizedInterval(base)
        return normalizedBase * max(1, multiplier)
    }
}

/// Pure deterministic state reducer for remote seek acceleration.
enum PlayerRemoteSeekReducer {
    /// Bounded idle timeout after which a continuous hold/press session commits.
    static let defaultIdleTimeout: TimeInterval = 0.45

    static func handle(
        state: inout PlayerRemoteSeekState,
        event: PlayerRemoteSeekEvent,
        playbackTime: Double,
        duration: Double,
        configuredInterval: Int
    ) -> PlayerRemoteSeekResult {
        switch event {
        case .playerMove(let dir, let timestamp):
            // Check if this move continues the active session
            let isSameDirection = (state.activeDirection == dir)
            let isWithinIdleWindow = (state.lastEventTime.map { (timestamp - $0) <= defaultIdleTimeout } ?? false)

            if isSameDirection && isWithinIdleWindow && !state.isCommitted {
                // Continuation of existing session
                let start = state.sessionStartTime ?? timestamp
                let elapsed = max(0, timestamp - start)
                state.repeatCount += 1
                state.lastEventTime = timestamp

                let mult = PlayerSeekAccelerationPolicy.multiplier(elapsed: elapsed)
                let effInterval = PlayerSeekAccelerationPolicy.effectiveInterval(base: configuredInterval, multiplier: mult)

                let currentBase = state.pendingTarget ?? playbackTime
                let nextTarget = PlayerSeekMath.target(
                    current: currentBase,
                    direction: dir,
                    interval: effInterval,
                    duration: duration
                ) ?? currentBase

                state.pendingTarget = nextTarget

                return PlayerRemoteSeekResult(
                    pendingTarget: nextTarget,
                    multiplier: mult,
                    effectiveInterval: effInterval,
                    shouldCommit: false,
                    commitTarget: nil
                )
            } else {
                // New session or direction reversal.
                // If reversing direction within an uncommitted active window, base from pendingTarget;
                // otherwise (fresh start or stale gap / post-commit), base from playbackTime.
                let currentBase: Double
                if isWithinIdleWindow && !state.isCommitted, let pending = state.pendingTarget {
                    currentBase = pending
                } else {
                    currentBase = playbackTime
                }

                state.activeDirection = dir
                state.sessionStartTime = timestamp
                state.lastEventTime = timestamp
                state.repeatCount = 0
                state.isCommitted = false

                let mult = 1
                let effInterval = PlayerSeekAccelerationPolicy.effectiveInterval(base: configuredInterval, multiplier: mult)

                let nextTarget = PlayerSeekMath.target(
                    current: currentBase,
                    direction: dir,
                    interval: effInterval,
                    duration: duration
                ) ?? currentBase

                state.pendingTarget = nextTarget

                return PlayerRemoteSeekResult(
                    pendingTarget: nextTarget,
                    multiplier: mult,
                    effectiveInterval: effInterval,
                    shouldCommit: false,
                    commitTarget: nil
                )
            }

        case .idleTimeout(let timestamp):
            guard let activeTarget = state.pendingTarget, !state.isCommitted else {
                return PlayerRemoteSeekResult(
                    pendingTarget: state.pendingTarget,
                    multiplier: 1,
                    effectiveInterval: PlayerSeekMath.normalizedInterval(configuredInterval),
                    shouldCommit: false,
                    commitTarget: nil
                )
            }

            // Verify timeout is truly at or after lastEventTime + defaultIdleTimeout
            if let last = state.lastEventTime, (timestamp - last) < (defaultIdleTimeout - 0.001) {
                return PlayerRemoteSeekResult(
                    pendingTarget: activeTarget,
                    multiplier: 1,
                    effectiveInterval: PlayerSeekMath.normalizedInterval(configuredInterval),
                    shouldCommit: false,
                    commitTarget: nil
                )
            }

            state.isCommitted = true
            state.activeDirection = nil
            state.sessionStartTime = nil
            state.lastEventTime = nil
            state.repeatCount = 0

            return PlayerRemoteSeekResult(
                pendingTarget: activeTarget,
                multiplier: 1,
                effectiveInterval: PlayerSeekMath.normalizedInterval(configuredInterval),
                shouldCommit: true,
                commitTarget: activeTarget
            )

        case .heartbeatTick:
            // Heartbeat ticks maintain state but NEVER advance targets or invent seeks
            return PlayerRemoteSeekResult(
                pendingTarget: state.pendingTarget,
                multiplier: 1,
                effectiveInterval: PlayerSeekMath.normalizedInterval(configuredInterval),
                shouldCommit: false,
                commitTarget: nil
            )

        case .reset:
            state = PlayerRemoteSeekState()
            return PlayerRemoteSeekResult(
                pendingTarget: nil,
                multiplier: 1,
                effectiveInterval: PlayerSeekMath.normalizedInterval(configuredInterval),
                shouldCommit: false,
                commitTarget: nil
            )
        }
    }
}
