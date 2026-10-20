import XCTest

/// Remote-interaction regression tests against the real `PlayerScreen` focus
/// hierarchy. The app is launched with `--uitest-player`, which mounts the
/// production view with a deterministic, fully offline playback session
/// (locally generated all-keyframe clip; no Quark/TMDB/network access).
///
/// Assertions combine focused-control identity (`hasFocus` on the real
/// buttons/cards) with side effects (playback time / play state read from the
/// live player via the harness readout).
final class PlayerRemoteInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Launch & probe helpers

    private func launchPlayer(seekInterval: Int) {
        app.launchArguments = ["--uitest-player", "-QuarkTheater.playerSeekIntervalSeconds", String(seekInterval)]
        app.launch()
        XCTAssertTrue(
            app.buttons["player.drawerTrigger"].waitForExistence(timeout: 90),
            "Player never became active (drawer trigger missing). Check the UI-test video factory log."
        )
    }

    private var timeText: XCUIElement { app.staticTexts["player.timeText"] }
    private var stateText: XCUIElement { app.staticTexts["player.playPauseState"] }
    private var durationText: XCUIElement { app.staticTexts["player.durationText"] }
    private var episodesTab: XCUIElement { app.buttons["player.tab.选集"] }

    private func currentTime() -> Double? {
        guard timeText.exists, let value = Double(timeText.label) else { return nil }
        return value
    }

    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func waitForPlayState(_ expected: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil(timeout) { self.stateText.exists && self.stateText.label == expected },
            "Play state never became '\(expected)' (last='\(stateText.label)')", file: file, line: line
        )
    }

    private func waitForDurationLoaded(timeout: TimeInterval = 60, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            waitUntil(timeout) { (Double(self.durationText.label) ?? 0) > 0 },
            "Media duration never became available (last='\(durationText.label)')", file: file, line: line
        )
    }

    private func pausePlayback(file: StaticString = #filePath, line: UInt = #line) {
        if stateText.label == "playing" {
            XCUIRemote.shared.press(.playPause)
            waitForPlayState("paused", file: file, line: line)
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One video frame at 10 fps is 0.1s; allow one frame of seek-landing
    /// jitter plus readback slack. The fixture is all-keyframe, so a larger
    /// deviation means the reducer or routing is wrong, not encoding noise.
    private let frameTolerance = 0.26

    // MARK: - Seek while drawer is closed

    func testSeekWithDrawerClosedAppliesConfiguredInterval15() throws {
        try runSeekAssertions(interval: 15)
    }

    func testSeekWithDrawerClosedAppliesConfiguredInterval10() throws {
        try runSeekAssertions(interval: 10)
    }

    private func runSeekAssertions(interval: Int) throws {
        launchPlayer(seekInterval: interval)
        waitForDurationLoaded()
        pausePlayback()
        guard let t0 = currentTime() else {
            return XCTFail("Playback time readout unavailable")
        }
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(
            waitUntil(10) { abs((self.currentTime() ?? -.infinity) - (t0 + Double(interval))) <= self.frameTolerance },
            "One right press must seek forward by exactly \(interval)s (t0=\(t0), now=\(currentTime() ?? -1))"
        )
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(
            waitUntil(10) { abs((self.currentTime() ?? -.infinity) - t0) <= self.frameTolerance },
            "One left press must seek back by exactly \(interval)s (expected \(t0), now=\(currentTime() ?? -1))"
        )
    }

    // MARK: - Drawer horizontal movement never seeks

    func testDrawerOpenLeftRightMovesFocusOneStepWithoutSeeking() throws {
        launchPlayer(seekInterval: 15)
        waitForDurationLoaded()
        pausePlayback()
        guard let t0 = currentTime() else {
            return XCTFail("Playback time readout unavailable")
        }

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(episodesTab.waitForExistence(timeout: 5), "Drawer did not open")
        XCTAssertTrue(
            waitUntil(5) { self.app.buttons["player.episodeCard.0"].hasFocus },
            "Opening the drawer must focus the currently playing episode card"
        )

        XCUIRemote.shared.press(.right)
        XCTAssertTrue(
            waitUntil(5) { self.app.buttons["player.episodeCard.1"].hasFocus },
            "One right press must move focus exactly one episode"
        )
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(
            waitUntil(5) { self.app.buttons["player.episodeCard.0"].hasFocus },
            "One left press must move focus exactly one episode back"
        )
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(
            waitUntil(5) { self.episodesTab.hasFocus },
            "Up from episode content must restore focus to the selected tab"
        )
        if episodesTab.exists {
            attachScreenshot("drawer-one-step-focus")
        }

        XCTAssertEqual(
            currentTime() ?? -1, t0, accuracy: frameTolerance,
            "Horizontal drawer navigation must leave playback time untouched (t0=\(t0), now=\(currentTime() ?? -1))"
        )
    }

    // MARK: - Drawer opens from ▼ after the hint fades

    func testDownPressAfterHintFadesOpensDrawer() throws {
        launchPlayer(seekInterval: 15)
        waitForDurationLoaded()
        // The hint pill auto-fades 3s after the session starts; the trigger
        // stays mounted but invisible. Wait past the fade, then press ▼.
        Thread.sleep(forTimeInterval: 4.5)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(
            episodesTab.waitForExistence(timeout: 5),
            "Drawer did not open on ▼ after the hint faded"
        )
        attachScreenshot("drawer-opened-after-hint-fade")
    }

    // MARK: - Play/pause

    func testPlayPauseCommandTogglesObservableState() throws {
        launchPlayer(seekInterval: 15)
        waitForDurationLoaded()
        XCTAssertTrue(
            waitUntil(20) { ["playing", "paused"].contains(self.stateText.label) },
            "Player never reached a settled state (last='\(stateText.label)')"
        )
        let initial = stateText.label
        XCUIRemote.shared.press(.playPause)
        waitForPlayState(initial == "playing" ? "paused" : "playing")
        XCUIRemote.shared.press(.playPause)
        waitForPlayState(initial)
    }

    // MARK: - Closing the drawer restores a visible focus target

    func testClosingDrawerRestoresVisibleFocusTarget() throws {
        launchPlayer(seekInterval: 15)
        waitForDurationLoaded()
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(episodesTab.waitForExistence(timeout: 5), "Drawer did not open")
        XCTAssertTrue(
            waitUntil(5) { self.app.buttons["player.episodeCard.0"].hasFocus },
            "Drawer open must place focus in episode content"
        )
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(
            waitUntil(5) { !self.episodesTab.exists },
            "Menu/back must close the drawer"
        )
        XCTAssertTrue(
            waitUntil(5) { self.app.buttons["player.drawerTrigger"].hasFocus },
            "Closing the drawer must restore focus to the (still-mounted) drawer trigger"
        )
    }
}
