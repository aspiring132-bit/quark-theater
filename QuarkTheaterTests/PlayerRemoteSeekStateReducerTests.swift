import XCTest
@testable import QuarkTheater

final class PlayerRemoteSeekStateReducerTests: XCTestCase {
    func testSinglePressBackwardUsesBaseIntervalOnly() {
        var state = PlayerRemoteSeekState()
        let result = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .backward, timestamp: 10.0),
            playbackTime: 100.0,
            duration: 500.0,
            configuredInterval: 10
        )

        XCTAssertEqual(result.pendingTarget, 90.0)
        XCTAssertEqual(result.multiplier, 1)
        XCTAssertEqual(result.effectiveInterval, 10)
        XCTAssertFalse(result.shouldCommit)
        XCTAssertEqual(state.activeDirection, .backward)
        XCTAssertEqual(state.repeatCount, 0)
    }

    func testSinglePressForwardUsesBaseIntervalOnly() {
        var state = PlayerRemoteSeekState()
        let result = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: 10.0),
            playbackTime: 100.0,
            duration: 500.0,
            configuredInterval: 15
        )

        XCTAssertEqual(result.pendingTarget, 115.0)
        XCTAssertEqual(result.multiplier, 1)
        XCTAssertEqual(result.effectiveInterval, 15)
        XCTAssertFalse(result.shouldCommit)
        XCTAssertEqual(state.activeDirection, .forward)
        XCTAssertEqual(state.repeatCount, 0)
    }

    func testRepeatedEventsAccelerateThroughTiers1x2x4x8x() {
        var state = PlayerRemoteSeekState()
        let t0 = 100.0
        let baseTime = 200.0
        let duration = 2000.0
        let interval = 10

        // Move 0: first press, elapsed = 0.0s -> Tier 1 (1x = 10s) -> 210.0
        let r0 = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: t0),
            playbackTime: baseTime,
            duration: duration,
            configuredInterval: interval
        )
        XCTAssertEqual(r0.multiplier, 1)
        XCTAssertEqual(r0.effectiveInterval, 10)
        XCTAssertEqual(r0.pendingTarget, 210.0)

        // Remote events arrive every ~250ms during physical hold
        // t = t0 + 0.25 (repeat 1, elapsed 0.25) -> Tier 1
        _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0 + 0.25), playbackTime: baseTime, duration: duration, configuredInterval: interval)
        // t = t0 + 0.50 (repeat 2, elapsed 0.50) -> Tier 1
        _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0 + 0.50), playbackTime: baseTime, duration: duration, configuredInterval: interval)
        // t = t0 + 0.75 (repeat 3, elapsed 0.75) -> Tier 1
        _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0 + 0.75), playbackTime: baseTime, duration: duration, configuredInterval: interval)

        // t = t0 + 1.00 (repeat 4, elapsed 1.00s >= 1.0s) -> Tier 2 (2x = 20s)
        let rTier2 = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: t0 + 1.00),
            playbackTime: baseTime,
            duration: duration,
            configuredInterval: interval
        )
        XCTAssertEqual(rTier2.multiplier, 2)
        XCTAssertEqual(rTier2.effectiveInterval, 20)

        // Advance through Tier 2 until >= 2.5s
        // t0 + 1.25, 1.50, 1.75, 2.00, 2.25
        for step in 1...5 {
            _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0 + 1.0 + Double(step) * 0.25), playbackTime: baseTime, duration: duration, configuredInterval: interval)
        }

        // t = t0 + 2.50 (elapsed 2.50s >= 2.5s) -> Tier 3 (4x = 40s)
        let rTier3 = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: t0 + 2.50),
            playbackTime: baseTime,
            duration: duration,
            configuredInterval: interval
        )
        XCTAssertEqual(rTier3.multiplier, 4)
        XCTAssertEqual(rTier3.effectiveInterval, 40)

        // Advance through Tier 3 until >= 5.0s
        for step in 1...10 {
            _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0 + 2.5 + Double(step) * 0.25), playbackTime: baseTime, duration: duration, configuredInterval: interval)
        }

        // t = t0 + 5.00 (elapsed 5.00s >= 5.0s) -> Tier 4 (8x = 80s)
        let rTier4 = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: t0 + 5.00),
            playbackTime: baseTime,
            duration: duration,
            configuredInterval: interval
        )
        XCTAssertEqual(rTier4.multiplier, 8)
        XCTAssertEqual(rTier4.effectiveInterval, 80)
    }

    func testElapsedDurationAdvancesTiersAccurately() {
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 0.0), 1)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 0.99), 1)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 1.0), 2)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 2.49), 2)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 2.5), 4)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 4.99), 4)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 5.0), 8)
        XCTAssertEqual(PlayerSeekAccelerationPolicy.multiplier(elapsed: 10.0), 8)
    }

    func testStaleGapExceedingIdleThresholdStartsNewSession() {
        var state = PlayerRemoteSeekState()
        let t0 = 10.0
        let baseTime = 100.0

        _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0), playbackTime: baseTime, duration: 500.0, configuredInterval: 10)
        _ = PlayerRemoteSeekReducer.handle(state: &state, event: .playerMove(direction: .forward, timestamp: t0 + 0.3), playbackTime: baseTime, duration: 500.0, configuredInterval: 10)

        // Gap of 0.6s exceeds default maxRepeatInterval (0.45s) -> idle timeout commits previous session
        let timeoutResult = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .idleTimeout(timestamp: t0 + 0.3 + 0.45),
            playbackTime: baseTime,
            duration: 500.0,
            configuredInterval: 10
        )
        XCTAssertTrue(timeoutResult.shouldCommit)
        XCTAssertEqual(timeoutResult.commitTarget, 120.0)
        XCTAssertNil(state.activeDirection)

        // Next move at t0 + 2.0 starts fresh from new playbackTime (e.g. 120.0)
        let freshResult = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: t0 + 2.0),
            playbackTime: 120.0,
            duration: 500.0,
            configuredInterval: 10
        )
        XCTAssertEqual(freshResult.multiplier, 1)
        XCTAssertEqual(freshResult.pendingTarget, 130.0)
        XCTAssertEqual(state.repeatCount, 0)
    }

    func testDirectionChangeResetsSessionAndAccumulation() {
        var state = PlayerRemoteSeekState()
        let t0 = 10.0
        let baseTime = 100.0

        // Move 1: Forward at 10.0 -> pendingTarget = 110.0
        let r1 = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: t0),
            playbackTime: baseTime,
            duration: 500.0,
            configuredInterval: 10
        )
        XCTAssertEqual(r1.pendingTarget, 110.0)
        XCTAssertEqual(state.pendingTarget, 110.0)
        XCTAssertEqual(r1.multiplier, 1)

        // Move 2: Backward within the same uncommitted window (t0 + 0.2s <= 0.45s)
        // Must start from pendingTarget (110.0) and step backward by 10s -> 100.0 (not 90.0)
        let reverseResult = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .backward, timestamp: t0 + 0.2),
            playbackTime: baseTime,
            duration: 500.0,
            configuredInterval: 10
        )
        XCTAssertEqual(state.activeDirection, .backward)
        XCTAssertEqual(state.repeatCount, 0, "Acceleration/session repeat count must reset on direction reversal")
        XCTAssertEqual(reverseResult.multiplier, 1, "Multiplier must reset to 1x on direction reversal")
        XCTAssertEqual(reverseResult.pendingTarget, 100.0, "Reversal must step backward from pendingTarget 110.0 back to 100.0, not from baseTime 100.0 to 90.0")

        // Move 3: Further backward repeat accumulates backward from 100.0 -> 90.0
        let repeatResult = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .backward, timestamp: t0 + 0.4),
            playbackTime: baseTime,
            duration: 500.0,
            configuredInterval: 10
        )
        XCTAssertEqual(state.activeDirection, .backward)
        XCTAssertEqual(state.repeatCount, 1)
        XCTAssertEqual(repeatResult.pendingTarget, 90.0)
    }

    func testClampingBoundariesToZeroAndDuration() {
        var state = PlayerRemoteSeekState()
        // Backward clamp to 0
        let rBack = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .backward, timestamp: 1.0),
            playbackTime: 5.0,
            duration: 100.0,
            configuredInterval: 10
        )
        XCTAssertEqual(rBack.pendingTarget, 0.0)

        // Forward clamp to duration
        var state2 = PlayerRemoteSeekState()
        let rForward = PlayerRemoteSeekReducer.handle(
            state: &state2,
            event: .playerMove(direction: .forward, timestamp: 1.0),
            playbackTime: 95.0,
            duration: 100.0,
            configuredInterval: 10
        )
        XCTAssertEqual(rForward.pendingTarget, 100.0)
    }

    func testIdleTimeoutCommitsExactlyOnce() {
        var state = PlayerRemoteSeekState()
        _ = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: 1.0),
            playbackTime: 50.0,
            duration: 100.0,
            configuredInterval: 10
        )

        let firstTimeout = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .idleTimeout(timestamp: 1.5),
            playbackTime: 50.0,
            duration: 100.0,
            configuredInterval: 10
        )
        XCTAssertTrue(firstTimeout.shouldCommit)
        XCTAssertEqual(firstTimeout.commitTarget, 60.0)

        let secondTimeout = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .idleTimeout(timestamp: 2.0),
            playbackTime: 50.0,
            duration: 100.0,
            configuredInterval: 10
        )
        XCTAssertFalse(secondTimeout.shouldCommit)
        XCTAssertNil(secondTimeout.commitTarget)
    }

    func testDrawerSuppressionKeepsReducerIdle() {
        // PlayerInputReducer guarantees when isDrawerOpen == true, left/right does not produce .seek
        let stateOpen = PlayerInputState(
            isDrawerOpen: true,
            selectedDrawerTab: "选集",
            focusedTarget: .drawerTab("选集"),
            canPlayNext: true,
            currentPlaybackTime: 50.0,
            duration: 100.0
        )
        let actionLeft = PlayerInputReducer.reduce(state: stateOpen, direction: .left, seekInterval: 10)
        let actionRight = PlayerInputReducer.reduce(state: stateOpen, direction: .right, seekInterval: 10)
        XCTAssertEqual(actionLeft, .none)
        XCTAssertEqual(actionRight, .none)
    }

    func testNeverInventsSeeksFromInternalTimerTicksWithoutRemoteEvents() {
        var state = PlayerRemoteSeekState()
        _ = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .playerMove(direction: .forward, timestamp: 1.0),
            playbackTime: 50.0,
            duration: 100.0,
            configuredInterval: 10
        )
        XCTAssertEqual(state.pendingTarget, 60.0)

        // Heartbeat or timer tick without an actual remote move event should NOT advance pendingTarget
        let tickResult = PlayerRemoteSeekReducer.handle(
            state: &state,
            event: .heartbeatTick(timestamp: 1.25),
            playbackTime: 50.0,
            duration: 100.0,
            configuredInterval: 10
        )
        XCTAssertEqual(tickResult.pendingTarget, 60.0)
        XCTAssertFalse(tickResult.shouldCommit)
        XCTAssertEqual(state.pendingTarget, 60.0)
    }
}
