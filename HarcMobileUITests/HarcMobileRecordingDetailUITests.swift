import XCTest

/// Simulator-safe UI coverage using a real durable synthetic WAV, never microphone capture.
@MainActor
final class HarcMobileRecordingDetailUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLocalDetailPlaybackSectionsAndReopening() {
        // Keep section-retention coverage independent of XCTest's best-effort
        // midpoint gesture. Long real audio cannot finish during slow navigation;
        // the dedicated 60-second case below retains the original seek checks.
        let app = launchFixture(longPlayback: true)
        openRecent(in: app)
        assertSavedDetail(in: app)
        let title = app.staticTexts["harc.mobile.detail.title"].label
        XCTAssertTrue(app.staticTexts["Summary not available yet"].exists)
        XCTAssertFalse(app.staticTexts["Saved on your Mac"].exists)

        let play = app.buttons["harc.mobile.detail.play"]
        reveal(play, in: app)
        assertSkipButtonTargets(in: app)
        play.tap()
        expectLabel("Pause", on: play)
        play.tap()
        expectLabel("Play", on: play)
        let position = app.sliders["Playback position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertTrue(position.isEnabled)
        let beforeSkip = position.value as? String ?? ""
        XCTAssertTrue(beforeSkip.hasSuffix(" seconds of 600 seconds"))
        guard let pausedSeconds = Int(beforeSkip.split(separator: " ").first ?? "") else {
            XCTFail("Playback position must expose seconds: \(beforeSkip)")
            return
        }
        app.buttons["Forward 15 seconds"].tap()
        XCTAssertEqual(position.value as? String, "\(pausedSeconds + 15) seconds of 600 seconds")
        XCTAssertEqual(play.label, "Play", "Skipping paused audio must not start playback")
        app.buttons["Back 15 seconds"].tap()
        XCTAssertEqual(position.value as? String, beforeSkip)
        XCTAssertEqual(play.label, "Play")
        play.tap()
        expectLabel("Pause", on: play)

        let sections = app.segmentedControls["harc.mobile.detail.sections"]
        reveal(sections, in: app)
        sections.buttons["Transcript"].tap()
        XCTAssertTrue(app.staticTexts["On-device transcript"].waitForExistence(timeout: 5))
        // Native speech availability varies by simulator. The local surface
        // must be reachable without a Host, regardless of model readiness.
        XCTAssertFalse(app.staticTexts["No transcript is available from your Mac yet."].exists)
        sections.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts[
            "Notes and title editing become available when this recording appears on your Mac."
        ].waitForExistence(timeout: 5))
        sections.buttons["Summary"].tap()
        XCTAssertTrue(app.staticTexts["Summary not available yet"].waitForExistence(timeout: 5))
        // Section changes retain the same playback controller.
        XCTAssertEqual(play.label, "Pause")
        XCTAssertTrue(app.buttons["harc.mobile.detail.newRecording"].isEnabled)
        keepScreenshot(app, named: "Local-recording-detail-pending")

        app.buttons["harc.mobile.detail.done"].tap()
        XCTAssertTrue(app.buttons["harc.mobile.record.recent"].waitForExistence(timeout: 10))
        openRecent(in: app)
        assertSavedDetail(in: app)
        XCTAssertEqual(app.staticTexts["harc.mobile.detail.title"].label, title)
        XCTAssertEqual(app.buttons["harc.mobile.detail.play"].label, "Play")
        app.buttons["harc.mobile.detail.done"].tap()

        app.tabBars.buttons["Library"].tap()
        let libraryRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        reveal(libraryRow, in: app)
        libraryRow.tap()
        assertSavedDetail(in: app)
        XCTAssertEqual(app.staticTexts["harc.mobile.detail.title"].label, title)
        XCTAssertTrue(app.buttons["harc.mobile.detail.newRecording"].isEnabled)
        XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
    }

    func testLocalDetailSeekPreservesPausedPlayback() {
        // Preserve the original real-audio midpoint/seconds/no-autoplay checks.
        // Staying paused after the gesture separates seek accuracy from EOF.
        let app = launchFixture()
        openRecent(in: app)
        assertSavedDetail(in: app)
        let play = app.buttons["harc.mobile.detail.play"]
        reveal(play, in: app)
        play.tap()
        expectLabel("Pause", on: play)
        play.tap()
        expectLabel("Play", on: play)
        let position = app.sliders["Playback position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertTrue(position.isEnabled)
        let beforeSeek = position.value as? String
        XCTAssertTrue(beforeSeek?.hasSuffix(" seconds of 60 seconds") == true)
        position.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertNotEqual(position.value as? String, beforeSeek)
        let seekValue = position.value as? String ?? ""
        XCTAssertTrue(seekValue.hasSuffix(" seconds of 60 seconds"))
        let seekSeconds = Int(seekValue.split(separator: " ").first ?? "")
        XCTAssertNotNil(seekSeconds)
        XCTAssertTrue((25...35).contains(seekSeconds ?? -1), "A midpoint seek must expose seconds, not percent: \(seekValue)")
        // Seeking paused audio must not silently start it.
        XCTAssertEqual(play.label, "Play")
    }

    func testLocalDetailRemainsUsableAtLargestDynamicType() {
        let app = launchFixture(largestText: true)
        openRecent(in: app)
        assertSavedDetail(in: app)
        let newRecording = app.buttons["harc.mobile.detail.newRecording"]
        XCTAssertTrue(newRecording.isEnabled)
        XCTAssertTrue(newRecording.isHittable)
        XCTAssertTrue(app.frame.contains(newRecording.frame))
        let play = app.buttons["harc.mobile.detail.play"]
        reveal(play, in: app)
        XCTAssertTrue(play.isEnabled)
        XCTAssertTrue(app.frame.contains(play.frame))
        assertSkipButtonTargets(in: app)
        play.tap()
        expectLabel("Pause", on: play)
        XCTAssertTrue(app.frame.contains(play.frame))
        XCTAssertLessThan(play.frame.height, 180, "Accessible playback uses a clear icon, not a fragmented word")
        keepScreenshot(app, named: "Local-recording-largest-text-playing")
        play.tap()
        expectLabel("Play", on: play)
        let sections = app.buttons["harc.mobile.detail.sections"]
        for name in ["Transcript", "Notes", "Summary"] {
            reveal(sections, in: app)
            sections.tap()
            let section = app.buttons[name]
            XCTAssertTrue(section.waitForExistence(timeout: 5))
            section.tap()
        }
        keepScreenshot(app, named: "Local-recording-detail-largest-text")
        let done = app.buttons["harc.mobile.detail.done"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.buttons["harc.mobile.record.recent"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
    }

    func testStorageWarningSurvivesDoneRecentAndLibrary() {
        let app = launchFixture(storageExhausted: true)
        openRecent(in: app)
        assertStorageWarning(in: app)
        let title = app.staticTexts["harc.mobile.detail.title"].label
        app.buttons["harc.mobile.detail.done"].tap()
        openRecent(in: app)
        assertStorageWarning(in: app)
        XCTAssertEqual(app.staticTexts["harc.mobile.detail.title"].label, title)
        app.buttons["harc.mobile.detail.done"].tap()
        app.tabBars.buttons["Library"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        reveal(row, in: app)
        row.tap()
        assertStorageWarning(in: app)
        XCTAssertEqual(app.staticTexts["harc.mobile.detail.title"].label, title)
        XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
        keepScreenshot(app, named: "Local-recording-persisted-storage-warning")
    }

    private func assertStorageWarning(in app: XCUIApplication) {
        assertSavedDetail(in: app)
        XCTAssertTrue(app.staticTexts[
            "Recording stopped when storage ran out. Harc saved the durable portion. Check free space before recording again."
        ].waitForExistence(timeout: 10))
        let newRecording = app.buttons["harc.mobile.detail.newRecording"]
        XCTAssertTrue(newRecording.exists)
        XCTAssertTrue(newRecording.isEnabled)
        XCTAssertTrue(app.buttons["harc.mobile.detail.play"].isEnabled)
    }

    private func assertSkipButtonTargets(in app: XCUIApplication) {
        for label in ["Back 15 seconds", "Forward 15 seconds"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.width + 0.001, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height + 0.001, 44)
        }
    }

    private func launchFixture(
        largestText: Bool = false, storageExhausted: Bool = false, longPlayback: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--harc-ui-test-root-id", UUID().uuidString,
            "--harc-ui-test-reset-root", "--harc-ui-test-local-recording",
        ]
        if storageExhausted {
            app.launchArguments.append("--harc-ui-test-local-recording-storage-exhausted")
        }
        if longPlayback {
            app.launchArguments.append("--harc-ui-test-long-playback-recording")
        }
        if largestText {
            app.launchEnvironment["HARC_SYNTHETIC_PLAYBACK_TRACE"] = "1"
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        addTeardownBlock { @MainActor in
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
        app.launch()
        return app
    }

    private func openRecent(in app: XCUIApplication) {
        let recent = app.buttons["harc.mobile.record.recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 20))
        reveal(recent, in: app)
        recent.tap()
    }

    private func assertSavedDetail(in app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "harc.mobile.detail")
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 10))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let navigation = app.navigationBars.firstMatch
        let top = navigation.exists ? navigation.frame.maxY : app.frame.minY
        let newRecording = app.buttons["harc.mobile.detail.newRecording"]
        let tabs = app.tabBars.firstMatch
        let bottom = newRecording.exists ? newRecording.frame.minY
            : (tabs.exists ? tabs.frame.minY : app.frame.maxY)
        for _ in 0..<16 {
            // List may not materialize offscreen rows at accessibility sizes.
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists, element.isHittable, frame.minY >= top + 8, frame.maxY <= bottom - 8 { break }
            // Short drags avoid overshooting a control behind the persistent CTA
            // at accessibility text sizes. SwipeUp can advance several rows.
            let centerY = top + (bottom - top) * 0.5
            let distance = min(140, (bottom - top) * 0.25)
            let down = !frame.isEmpty && frame.minY < top + 8
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: centerY + (down ? -distance / 2 : distance / 2)))
            let end = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: centerY + (down ? distance / 2 : -distance / 2)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minY, top)
        XCTAssertLessThanOrEqual(element.frame.maxY, bottom)
    }

    private func expectLabel(_ label: String, on element: XCUIElement) {
        expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    private func keepScreenshot(_ app: XCUIApplication, named name: String) {
        // Native menu/button material transitions can outlive XCTest's idle
        // signal. Keep evidence after compositing settles, not mid-transition.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.buttons["harc.mobile.detail.newRecording"].label, "New recording")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
