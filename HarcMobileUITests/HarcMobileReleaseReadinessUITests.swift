import XCTest

@MainActor
final class HarcMobileReleaseReadinessUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordingEntryIsExplicitAndDisclosesLocalHandling() {
        let app = makeApp(rootID: TestRoot.recordingEntry)
        app.launch()

        let recordTab = app.tabBars.buttons["Record"]
        XCTAssertTrue(recordTab.waitForExistence(timeout: 10))
        recordTab.tap()

        XCTAssertTrue(
            app.staticTexts["Tap to record"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "Records to protected storage on this iPhone"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.buttons["harc.mobile.record.start"].exists
        )
    }

    func testLocalLibraryIsReachableWithoutHost() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.staticTexts["On This iPhone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[
            "Recordings saved on this iPhone appear here, even without a Host."
        ].exists)
    }

    func testSyncDetailsAreDiscoverableWithoutHostOrRecording() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()

        let hostPill = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(hostPill.waitForExistence(timeout: 10))
        hostPill.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.setup-and-sync"
            ].waitForExistence(timeout: 10)
        )

        let status = app.buttons["harc.mobile.host.sync-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        status.tap()
        let transferStatus = app.descendants(matching: .any)["harc.mobile.sync.transfer-status"]
        XCTAssertTrue(transferStatus.waitForExistence(timeout: 10))
        XCTAssertTrue(transferStatus.label.contains("Transfers not enabled in this build"))
        let hostStatus = app.descendants(matching: .any)["harc.mobile.sync.host"]
        XCTAssertTrue(hostStatus.exists)
        XCTAssertFalse(app.buttons["harc.mobile.sync.retry-transfers"].exists)
        let local = app.buttons["harc.mobile.sync.local-recordings"]
        XCTAssertTrue(scrollUntilExists(local, in: app))
        local.tap()
        XCTAssertTrue(app.navigationBars["On This iPhone"].waitForExistence(timeout: 10))
    }

    func testLibrarySearchLivesInTheSearchTab() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.search"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Recordings still on this iPhone match by title only."
            ].exists
        )
        XCTAssertTrue(
            app.searchFields[
                "Search Host titles, tags, and transcripts"
            ].exists
        )
    }

    func testSetupAndSyncOpensFromLibraryHostPill() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        selectTab("Library", in: app)
        openSetupAndSync(in: app)
        XCTAssertTrue(
            app.buttons["harc.mobile.host.sync-status"]
                .waitForExistence(timeout: 10)
        )
    }

    func testSendingStatusOpensFromSetupAndSync() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        openSetupAndSync(in: app)

        let sending = app.buttons["harc.mobile.host.sync-status"]
        XCTAssertTrue(sending.waitForExistence(timeout: 10))
        sending.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.sync.transfer-status"
            ].waitForExistence(timeout: 10)
        )
    }

    func testEmptyLocalRecordingsOpenFromSetupAndSync() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        openSetupAndSync(in: app)
        openLocalRecordingsFromSetupAndSync(in: app)
    }

    func testRepeatedSetupAndSyncPresentationPreservesSelectedTab() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()

        for tabName in ["Library", "Record", "Library"] {
            selectTab(tabName, in: app)
            openSetupAndSync(in: app)
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            done.tap()
            XCTAssertTrue(
                app.tabBars.buttons[tabName]
                    .waitForExistence(timeout: 10)
            )
            XCTAssertTrue(app.tabBars.buttons[tabName].isSelected)
        }
    }

    private func selectTab(_ name: String, in app: XCUIApplication) {
        let matches = app.tabBars.buttons.matching(identifier: name)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(matches.count, 1)
        let tab = matches.element(boundBy: 0)
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: tab
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        tab.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: tab
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    private func openSetupAndSync(in app: XCUIApplication) {
        let hostPill = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(hostPill.waitForExistence(timeout: 10))
        hostPill.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.setup-and-sync"
            ].waitForExistence(timeout: 10)
        )
    }

    private func openLocalRecordingsFromSetupAndSync(
        in app: XCUIApplication
    ) {
        let storage = app.buttons["Recordings & storage"]
        if storage.waitForExistence(timeout: 1) {
            storage.tap()
            assertVisibleEmptyLocalRecordings(in: app)
            return
        }

        let sending = app.buttons["harc.mobile.host.sync-status"]
        XCTAssertTrue(sending.waitForExistence(timeout: 10))
        sending.tap()
        let local = app.buttons["harc.mobile.sync.local-recordings"]
        XCTAssertTrue(scrollUntilExists(local, in: app))
        local.tap()
        assertVisibleEmptyLocalRecordings(in: app)
    }

    private func assertVisibleEmptyLocalRecordings(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["On This iPhone"].waitForExistence(timeout: 10))
        let destination = app.descendants(matching: .any)[
            "harc.mobile.local-recordings"
        ]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(destination.frame.width, 0)
        let empty = app.staticTexts["No recordings yet"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue(empty.isHittable)
        XCTAssertGreaterThan(empty.frame.width, 0)
        XCTAssertTrue(app.staticTexts[
            "Recordings saved on this iPhone appear here, even without a Host."
        ].exists)
    }

    func testOfflineReviewSampleAndPrivacyAreReachableWithoutHost() {
        let app = makeApp(rootID: TestRoot.offlineReview)
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
        let sampleAudio = app.buttons[
            "harc.mobile.reviewSample.audio"
        ]
        XCTAssertTrue(
            scrollUntilExists(sampleAudio, in: app),
            "Review sample audio must remain reachable at large text sizes."
        )

        let closeSample = app.buttons["Close Review Sample"]
        XCTAssertTrue(closeSample.waitForExistence(timeout: 10))
        closeSample.tap()

        let hostPill = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(hostPill.waitForExistence(timeout: 10))
        hostPill.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.setup-and-sync"
            ].waitForExistence(timeout: 10)
        )
        let privacy = app.buttons["Privacy & Data"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.privacy"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.staticTexts["Harc's privacy model"].exists)
    }

    func testCriticalOfflineSurfacesPassAccessibilityAudit() throws {
        let app = makeApp(rootID: TestRoot.accessibilityAudit)
        app.launch()

        let recordTab = app.tabBars.buttons["Record"]
        XCTAssertTrue(recordTab.waitForExistence(timeout: 10))
        recordTab.tap()
        XCTAssertTrue(
            app.staticTexts["Tap to record"]
                .waitForExistence(timeout: 10)
        )
        try performAccessibilityAudit(in: app, surface: "Record")

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        libraryTab.tap()
        let openSample = app.buttons[
            "harc.mobile.reviewSample.open.toolbar"
        ]
        XCTAssertTrue(openSample.waitForExistence(timeout: 10))
        openSample.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.reviewSample.root"]
                .waitForExistence(timeout: 10)
        )
        try performAccessibilityAudit(in: app, surface: "Review Sample")

        let closeSample = app.buttons["Close Review Sample"]
        XCTAssertTrue(closeSample.waitForExistence(timeout: 10))
        closeSample.tap()
        let hostPill = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(hostPill.waitForExistence(timeout: 10))
        hostPill.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "harc.mobile.setup-and-sync"
            ].waitForExistence(timeout: 10)
        )
        let privacy = app.buttons["Privacy & Data"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["harc.mobile.privacy"]
                .waitForExistence(timeout: 10)
        )
        try performAccessibilityAudit(in: app, surface: "Privacy & Data")
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

        let app = makeApp(rootID: TestRoot.microphone)
        app.launch()

        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        triggerMicrophonePermissionMonitor(in: app)

        XCTAssertTrue(
            app.buttons["harc.mobile.record.stop"]
                .waitForExistence(timeout: 15)
        )

        let libraryTab = app.tabBars.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10))
        libraryTab.tap()
        let stop = app.buttons["harc.mobile.record.accessory.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)

        let capturedAudio = expectation(description: "capture real microphone audio")
        _ = XCTWaiter.wait(for: [capturedAudio], timeout: 2)
        stop.tap()

        let recordTab = app.tabBars.buttons["Record"]
        XCTAssertTrue(recordTab.waitForExistence(timeout: 10))
        recordTab.tap()
        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
#endif
    }

    func testPhysicalStorageExhaustionPreservesVisibleDurablePrefix() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("C7 storage exhaustion requires a physical iPhone.")
#else
        addUIInterruptionMonitor(
            withDescription: "Microphone permission"
        ) { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        let app = makeApp(
            rootID: TestRoot.storageExhaustion,
            additionalArguments: [
                "--harc-capture-storage-exhaustion-after-canonical-bytes",
                "160000",
            ]
        )
        app.launch()

        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        triggerMicrophonePermissionMonitor(in: app)

        XCTAssertTrue(
            app.buttons["harc.mobile.record.stop"]
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            app.staticTexts["iPhone storage is full"]
                .waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Recording stopped. Harc saved the durable portion locally."
            ].exists
        )
        XCTAssertTrue(app.buttons["Record Again"].exists)
        XCTAssertEqual(app.state, .runningForeground)
#endif
    }

    func testPhysicalForceQuitRecoversDurablePrefixOnRelaunch() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("C5 force-quit recovery requires a physical iPhone.")
#else
        addUIInterruptionMonitor(
            withDescription: "Microphone permission"
        ) { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }

        let app = makeApp(rootID: TestRoot.forceQuitRecovery)
        app.launch()

        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        triggerMicrophonePermissionMonitor(in: app)
        XCTAssertTrue(
            app.buttons["harc.mobile.record.stop"]
                .waitForExistence(timeout: 15)
        )

        let durableCheckpoint = expectation(
            description: "capture enough audio for a durable checkpoint"
        )
        _ = XCTWaiter.wait(for: [durableCheckpoint], timeout: 7)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)

        // Preserve the intentionally interrupted root for recovery while
        // removing the reset argument used by the first process launch.
        app.launchArguments = launchArguments(
            rootID: TestRoot.forceQuitRecovery,
            resetRoot: false
        )
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Recovered 1 durable recording"]
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(app.staticTexts["Tap to record"].exists)
        XCTAssertEqual(app.state, .runningForeground)
#endif
    }

    private enum TestRoot {
        static let recordingEntry =
            "A1000000-0000-4000-8000-202608090001"
        static let offlineReview =
            "A2000000-0000-4000-8000-202608090001"
        static let microphone =
            "A3000000-0000-4000-8000-202608090001"
        static let accessibilityAudit =
            "A4000000-0000-4000-8000-202608090001"
        static let forceQuitRecovery =
            "C5000000-0000-4000-8000-202608090001"
        static let storageExhaustion =
            "C7000000-0000-4000-8000-202608090001"
    }

    private func makeApp(
        rootID: String,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = launchArguments(
            rootID: rootID,
            resetRoot: true
        ) + additionalArguments
        addTeardownBlock { @MainActor () async throws -> Void in
            // End this test's process before another test asks launch() to
            // replace it. A failed termination remains a test failure.
            if app.state != .notRunning {
                app.terminate()
            }
            let stopped = app.wait(for: .notRunning, timeout: 10)
            print("UI_APP_LIFECYCLE stopped=\(stopped) state=\(app.state.rawValue)")
            XCTAssertTrue(stopped, "The owned UI-test app must exit before the next launch.")
        }
        return app
    }

    private func launchArguments(
        rootID: String,
        resetRoot: Bool
    ) -> [String] {
        var arguments = ["--harc-ui-test-root-id", rootID]
        if resetRoot { arguments.append("--harc-ui-test-reset-root") }
        return arguments
    }

    private func triggerMicrophonePermissionMonitor(
        in app: XCUIApplication
    ) {
        // XCTest needs an app interaction before it invokes interruption
        // monitors. Keep the fallback tap away from the central recording
        // control so an already-authorized device does not stop capture.
        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.12)
        ).tap()
    }

    private func scrollUntilExists(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.exists { return true }
        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 0.5) { return true }
        }
        return false
    }

    private func performAccessibilityAudit(
        in app: XCUIApplication,
        surface: String
    ) throws {
        var findings: [String] = []
        try app.performAccessibilityAudit { issue in
            let finding =
                "HARC_ACCESSIBILITY_AUDIT surface=\(surface) "
                    + "type=\(issue.auditType.rawValue) "
                    + "compact=\(issue.compactDescription) "
                    + "detail=\(issue.detailedDescription) "
                    + "element=\(String(describing: issue.element))"
            findings.append(finding)
            print(finding)
            return true
        }
        XCTAssertTrue(
            findings.isEmpty,
            "Accessibility audit found \(findings.count) issue(s) on \(surface)."
        )
    }
}
