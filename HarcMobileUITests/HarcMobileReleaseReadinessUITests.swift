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
}
