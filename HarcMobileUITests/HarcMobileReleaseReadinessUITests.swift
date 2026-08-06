import XCTest

final class HarcMobileReleaseReadinessUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordingEntryIsExplicitAndDisclosesLocalHandling() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--harc-ui-test-root-id", UUID().uuidString,
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Ready to record locally"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "keeps a protected copy on this iPhone"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.buttons["harc.mobile.record.start"].exists
        )
    }

    func testOfflineReviewSampleAndPrivacyAreReachableWithoutHost() {
        let app = XCUIApplication()
        app.launchArguments += [
            "--harc-ui-test-root-id", UUID().uuidString,
        ]
        app.launch()

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        libraryTab.tap()

        let openSample = app.buttons[
            "harc.mobile.reviewSample.open.toolbar"
        ]
        XCTAssertTrue(openSample.waitForExistence(timeout: 10))
        openSample.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.reviewSample.root"
            ].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["Bundled, read-only sample"].exists)
        XCTAssertTrue(
            app.buttons["harc.mobile.reviewSample.audio"].exists
        )

        app.buttons["Privacy & Data"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.privacy"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["Harc's privacy model"].exists)
    }

    func testPhysicalMicrophoneRecordingStartsAndStopsWithoutProcessExit() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Real microphone capture requires a physical iPhone.")
#else
        addUIInterruptionMonitor(
            withDescription: "Microphone permission"
        ) { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        let app = XCUIApplication()
        app.launchArguments += [
            "--harc-ui-test-root-id", UUID().uuidString,
        ]
        app.launch()

        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        // Triggers the interruption monitor when this installation has not
        // granted microphone access yet; otherwise it is a harmless tap.
        app.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.record.banner"]
                .waitForExistence(timeout: 15)
        )
        let stop = app.buttons["harc.mobile.record.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))

        let capturedAudio = expectation(description: "capture real microphone audio")
        _ = XCTWaiter.wait(for: [capturedAudio], timeout: 2)
        stop.tap()

        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
#endif
    }
}
