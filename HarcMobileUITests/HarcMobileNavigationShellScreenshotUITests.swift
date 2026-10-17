import XCTest

@MainActor
final class HarcMobileNavigationShellScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureNavigationShellSurfaces() {
        addUIInterruptionMonitor(
            withDescription: "Microphone permission"
        ) { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "--harc-ui-test-root-id",
            "A5000000-0000-4000-8000-202610170001",
            "--harc-ui-test-reset-root",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tap to record"].waitForExistence(timeout: 15)
        )
        keepScreenshot(named: "pr1-record-idle")

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.search"]
                .waitForExistence(timeout: 10)
        )
        keepScreenshot(named: "pr1-search")

        app.tabBars.buttons["Record"].tap()
        let hostPill = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(hostPill.waitForExistence(timeout: 10))
        hostPill.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.setup-and-sync"
            ].waitForExistence(timeout: 10)
        )
        keepScreenshot(named: "pr1-setup-and-sync")

        app.buttons["Done"].tap()
        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        triggerPermissionMonitor(in: app)
        XCTAssertTrue(
            app.buttons["harc.mobile.record.stop"]
                .waitForExistence(timeout: 15)
        )

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        libraryTab.tap()
        let accessoryStop = app.buttons[
            "harc.mobile.record.accessory.stop"
        ]
        XCTAssertTrue(accessoryStop.waitForExistence(timeout: 10))
        keepScreenshot(named: "pr1-library-recording")
        accessoryStop.tap()
    }

    private func triggerPermissionMonitor(in app: XCUIApplication) {
        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.12)
        ).tap()
    }

    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(
            screenshot: XCUIScreen.main.screenshot()
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
