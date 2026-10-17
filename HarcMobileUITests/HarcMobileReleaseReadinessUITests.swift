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
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let status = app.buttons["harc.mobile.library.sync-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Sync status")
        XCTAssertGreaterThanOrEqual(status.frame.height, 44)
        status.tap()
        let transferStatus = app.descendants(matching: .any)["harc.mobile.sync.transfer-status"]
        XCTAssertTrue(transferStatus.waitForExistence(timeout: 10))
        XCTAssertTrue(transferStatus.label.contains("Transfers not enabled in this build"))
        let hostStatus = app.descendants(matching: .any)["harc.mobile.sync.host"]
        XCTAssertTrue(hostStatus.exists)
        XCTAssertTrue((hostStatus.label + " " + String(describing: hostStatus.value ?? "")).contains("No Host paired"))
        XCTAssertFalse(app.buttons["harc.mobile.sync.retry-transfers"].exists)
        let local = app.buttons["harc.mobile.sync.local-recordings"]
        XCTAssertTrue(scrollUntilExists(local, in: app))
        local.tap()
        XCTAssertTrue(app.navigationBars["On This iPhone"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Host"].tap()
        let hostLink = app.buttons["harc.mobile.host.sync-status"]
        XCTAssertTrue(hostLink.waitForExistence(timeout: 10))
        hostLink.tap()
        XCTAssertTrue(transferStatus.waitForExistence(timeout: 10))
        XCTAssertTrue(transferStatus.label.contains("Transfers not enabled in this build"))
        XCTAssertFalse(app.buttons["Retry transfers"].exists)
    }

    func testHostTabFromLibraryRootControl() {
        assertHostTabNavigation(openSync: false, openLocalRecordings: false)
    }

    func testHostTabFromSyncControl() {
        assertHostTabNavigation(openSync: true, openLocalRecordings: false)
    }

    func testHostTabFromEmptyLocalRecordings() {
        assertHostTabNavigation(openSync: true, openLocalRecordings: true)
    }

    private func assertHostTabNavigation(
        openSync: Bool,
        openLocalRecordings: Bool
    ) {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let libraryStatus = app.buttons["harc.mobile.library.sync-status"]
        XCTAssertTrue(libraryStatus.waitForExistence(timeout: 10))
        if openSync {
            libraryStatus.tap()
            XCTAssertTrue(app.descendants(matching: .any)[
                "harc.mobile.sync.transfer-status"
            ].waitForExistence(timeout: 10))
        }
        if openLocalRecordings {
            let local = app.buttons["harc.mobile.sync.local-recordings"]
            XCTAssertTrue(scrollUntilExists(local, in: app))
            local.tap()
            XCTAssertTrue(app.navigationBars["On This iPhone"].waitForExistence(timeout: 10))
            print("NAV_DIAG localScrollFrames=\(app.scrollViews.allElementsBoundByIndex.map(\.frame))")
        }
        let matches = app.tabBars.buttons.matching(identifier: "Host")
        XCTAssertEqual(matches.count, 1, "Host tab targeting must be unique")
        let host = matches.element(boundBy: 0)
        print("NAV_DIAG sync=\(openSync) local=\(openLocalRecordings) hostFrame=\(host.frame) hittable=\(host.isHittable) selectedBefore=\(host.isSelected)")
        host.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: host
        )
        let selectionResult = XCTWaiter.wait(for: [selected], timeout: 10)
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "Host tab after one tap; sync=\(openSync), local=\(openLocalRecordings)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(selectionResult, .completed, "One Host tap must select Host")
        XCTAssertTrue(app.buttons["harc.mobile.host.sync-status"].waitForExistence(timeout: 10))
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

        let privacy = app.buttons["Privacy & Data"]
        XCTAssertTrue(
            scrollUntilExists(privacy, in: app),
            "Privacy & Data must remain reachable at large text sizes."
        )
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

        let privacy = app.buttons["Privacy & Data"]
        XCTAssertTrue(scrollUntilExists(privacy, in: app))
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

        let stop = app.buttons["harc.mobile.record.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))

        let capturedAudio = expectation(description: "capture real microphone audio")
        _ = XCTWaiter.wait(for: [capturedAudio], timeout: 2)
        stop.tap()

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
