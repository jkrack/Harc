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
                    "Saved on this iPhone first, then sent to your Mac"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.buttons["harc.mobile.record.start"].exists
        )
        keepTideScreenshot("Tide-Record")
    }

    func testRecordEmptyTodayRemainsNavigableAtLargestText() {
        let timelineID = "harc.mobile.record.today.timeline"
        let populated = makeApp(
            rootID: TestRoot.recordingEntry,
            additionalArguments: [
                "--harc-ui-test-today-timeline",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        )
        populated.launch()
        XCTAssertTrue(populated.buttons["harc.mobile.record.start"].waitForExistence(timeout: 15))
        let populatedToday = populated.buttons["harc.mobile.record.today"]
        XCTAssertTrue(populatedToday.waitForExistence(timeout: 10), "Today must retain its navigable button role")
        for _ in 0..<5 where !populatedToday.isHittable { populated.swipeUp() }
        // Query the informational Canvas role explicitly and reject duplicate nodes.
        let populatedTimelines = populated.otherElements.matching(identifier: timelineID)
        let populatedTimeline = populatedTimelines.element
        XCTAssertTrue(populatedTimeline.waitForExistence(timeout: 10))
        XCTAssertEqual(populatedTimelines.count, 1)
        XCTAssertEqual(populated.descendants(matching: .any).matching(identifier: timelineID).count, 1)
        // The Canvas is informational, not an action. Check its rendered frame
        // against the unobscured viewport; hittability belongs to the Today button.
        func timelineViewport() -> CGRect {
            let scroll = populated.scrollViews.firstMatch.frame.intersection(populated.frame)
            let tabBar = populated.tabBars.firstMatch
            let bottom = tabBar.exists ? min(scroll.maxY, tabBar.frame.minY) : scroll.maxY
            return CGRect(x: scroll.minX, y: scroll.minY, width: scroll.width,
                          height: max(0, bottom - scroll.minY))
        }
        for _ in 0..<5 where !timelineViewport().contains(populatedTimeline.frame) {
            populated.swipeUp()
        }
        let fixtureAttachment = XCTAttachment(screenshot: populated.screenshot())
        fixtureAttachment.name = "Record-populated-timeline-presentation-fixture-largest-text"
        fixtureAttachment.lifetime = .keepAlways
        add(fixtureAttachment)
        XCTAssertTrue(populatedToday.isHittable)
        XCTAssertFalse(populatedTimeline.frame.isEmpty)
        XCTAssertTrue(
            timelineViewport().contains(populatedTimeline.frame),
            "Timeline frame \(populatedTimeline.frame) must fit viewport \(timelineViewport())"
        )
        XCTAssertTrue(populated.staticTexts["1 recording · 5 min"].exists)
        XCTAssertEqual(populated.buttons.matching(identifier: "harc.mobile.record.today").count, 1)
        populatedToday.tap()
        let populatedRecordings = populated.navigationBars["On This iPhone"]
        XCTAssertTrue(populatedRecordings.waitForExistence(timeout: 10))
        XCTAssertFalse(populated.buttons["harc.mobile.record.stop"].exists)
        populated.buttons["Done"].tap()
        XCTAssertTrue(populatedRecordings.waitForNonExistence(timeout: 10))
        XCTAssertTrue(populatedToday.waitForExistence(timeout: 10))
        XCTAssertTrue(populatedTimeline.waitForExistence(timeout: 10))
        XCTAssertTrue(populatedToday.isHittable)
        populated.terminate()
        XCTAssertTrue(populated.wait(for: .notRunning, timeout: 10))

        let app = makeApp(rootID: TestRoot.recordingEntry)
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let connection = app.buttons["harc.mobile.host.health"]
        XCTAssertEqual(connection.label, "Mac connection")
        XCTAssertEqual(connection.value as? String, "No Mac paired")
        let today = app.buttons["harc.mobile.record.today"]
        XCTAssertTrue(today.waitForExistence(timeout: 10), "Empty Today must retain its navigable button role")
        for _ in 0..<5 where !today.isHittable { app.swipeUp() }
        XCTAssertTrue(today.isHittable)
        XCTAssertTrue(app.staticTexts["No recordings yet"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "harc.mobile.record.today").count, 1)
        XCTAssertEqual(app.otherElements.matching(identifier: timelineID).count, 0)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: timelineID).count, 0)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Record-empty-largest-text"
        attachment.lifetime = .keepAlways
        add(attachment)
        today.tap()
        XCTAssertTrue(app.navigationBars["On This iPhone"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
    }

    func testTideSearchAndSetupAreReachableWithoutStartingCapture() {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        let search = app.tabBars.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        XCTAssertTrue(app.staticTexts["Find a moment"].waitForExistence(timeout: 10))
        keepTideScreenshot("Tide-Search")
        let setup = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10))
        setup.tap()
        XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Pair a Mac"].exists)
        keepTideScreenshot("Tide-Setup")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["harc.mobile.search"].waitForExistence(timeout: 5))
        // iOS can replace the selected Search tab button with its native
        // search field. Verify the returned screen and usable control.
        let searchField = app.searchFields["Search meetings and transcripts"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(searchField.isHittable)
        keepTideScreenshot("Tide-Search-After-Setup")
        XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
    }

    func testLocalLibraryIsReachableWithoutHost() throws {
        let app = makeApp(rootID: TestRoot.offlineReview)
        app.launch()
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        let status = app.descendants(matching: .any)["harc.mobile.library.refresh-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let unpaired = NSPredicate(format: "label CONTAINS %@", "Pair a Mac for its Library")
        expectation(for: unpaired, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["No recordings yet"].exists)
        let setup = app.buttons["harc.mobile.library.refresh-action"]
        XCTAssertTrue(setup.isEnabled)
        setup.tap()
        XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(unpaired.evaluate(with: status))

        // Exercise the real Library-attention destination with cached metadata
        // and no Host adoption, microphone, audio or network fixture.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let cachedApp = makeApp(
            rootID: TestRoot.offlineReview,
            additionalArguments: ["--harc-ui-test-cached-library"]
        )
        cachedApp.launch()
        selectTab("Library", in: cachedApp)
        let attention = cachedApp.buttons["harc.mobile.library.attention"]
        XCTAssertTrue(attention.waitForExistence(timeout: 10))
        attention.tap()
        XCTAssertTrue(cachedApp.navigationBars["Sending to Mac"].waitForExistence(timeout: 10))
        let retainedStatus = cachedApp.descendants(matching: .any)["harc.mobile.library.refresh-status"]
        XCTAssertTrue(scrollUntilExists(retainedStatus, in: cachedApp))
        let offline = NSPredicate(format: "label CONTAINS %@", "Couldn’t refresh Mac Library")
        expectation(for: offline, evaluatedWith: retainedStatus)
        waitForExpectations(timeout: 10)
        for _ in 0..<2 {
            let recovery = try XCTUnwrap(
                scrollToHittableButton("harc.mobile.library.refresh-setup", in: cachedApp),
                recoveryDiagnostics(in: cachedApp)
            )
            recovery.tap()
            XCTAssertTrue(cachedApp.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
            // Sending inside this sheet must return to this same setup root.
            cachedApp.buttons["harc.mobile.host.sync-status"].tap()
            XCTAssertTrue(cachedApp.navigationBars["Sending to Mac"].waitForExistence(timeout: 10))
            let sheetRecovery = try XCTUnwrap(
                scrollToHittableButton("harc.mobile.library.refresh-setup", in: cachedApp),
                recoveryDiagnostics(in: cachedApp)
            )
            sheetRecovery.tap()
            XCTAssertTrue(cachedApp.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
            cachedApp.buttons["Done"].tap()
            XCTAssertTrue(cachedApp.navigationBars["Setup & Sync"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(cachedApp.navigationBars["Sending to Mac"].waitForExistence(timeout: 10))
            XCTAssertTrue(cachedApp.navigationBars["Sending to Mac"].buttons["Library"].exists)
            XCTAssertTrue(scrollUntilExists(retainedStatus, in: cachedApp))
            XCTAssertTrue(offline.evaluate(with: retainedStatus))
        }
        cachedApp.navigationBars["Sending to Mac"].buttons["Library"].tap()
        XCTAssertTrue(cachedApp.navigationBars["Library"].waitForExistence(timeout: 10))
        XCTAssertTrue(cachedApp.tabBars.buttons["Library"].isSelected)
    }

    func testSyncDetailsAreDiscoverableWithoutHostOrRecording() throws {
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
        let unpairedStatus = NSPredicate(
            format: "label CONTAINS %@",
            "Local recording, playback and export work without a Mac."
        )
        expectation(for: unpairedStatus, evaluatedWith: transferStatus)
        waitForExpectations(timeout: 10)
        let sendNow = app.buttons["harc.mobile.sync.retry-transfers"]
        XCTAssertTrue(sendNow.exists)
        XCTAssertFalse(sendNow.isEnabled)

        XCTAssertFalse(app.staticTexts["Everything is up to date"].exists)
        let libraryStatus = app.descendants(matching: .any)["harc.mobile.library.refresh-status"]
        XCTAssertTrue(scrollUntilExists(libraryStatus, in: app))
        let unpairedLibrary = NSPredicate(format: "label CONTAINS %@", "Pair a Mac for its Library")
        expectation(for: unpairedLibrary, evaluatedWith: libraryStatus)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["harc.mobile.library.refresh-action"].isEnabled)
        for _ in 0..<2 {
            let recovery = try XCTUnwrap(
                scrollToHittableButton("harc.mobile.library.refresh-action", in: app),
                recoveryDiagnostics(in: app)
            )
            recovery.tap()
            XCTAssertTrue(app.navigationBars["Sending to Mac"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
            status.tap()
            XCTAssertTrue(app.navigationBars["Sending to Mac"].waitForExistence(timeout: 10))
            XCTAssertTrue(scrollUntilExists(libraryStatus, in: app))
            XCTAssertTrue(unpairedLibrary.evaluate(with: libraryStatus))
        }

        let setupBack = app.navigationBars["Sending to Mac"]
            .buttons["Setup & Sync"]
        XCTAssertTrue(setupBack.waitForExistence(timeout: 10))
        setupBack.tap()
        let local = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Recordings & storage"
            )
        ).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10))
        local.tap()
        XCTAssertTrue(app.navigationBars["On This iPhone"].waitForExistence(timeout: 10))
        app.navigationBars["On This iPhone"].buttons["Setup & Sync"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Record"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Record"].isSelected)
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
                "Recordings only on this iPhone are matched by title until they reach your Mac."
            ].exists
        )
        XCTAssertTrue(
            app.searchFields[
                "Search meetings and transcripts"
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
        let storage = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Recordings & storage"
            )
        ).firstMatch
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
        let empty = app.staticTexts.matching(
            NSPredicate(
                format: "label IN %@",
                ["No recordings yet", "No recordings on this iPhone"]
            )
        ).firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertTrue(empty.isHittable)
        XCTAssertGreaterThan(empty.frame.width, 0)
    }

    func testOfflineReviewSampleAndPrivacyAreReachableWithoutHost() {
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
        let advanced = app.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.tap()
        let openSample = app.buttons["harc.mobile.reviewSample.open"]
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

        let setupBack = app.navigationBars["Advanced"]
            .buttons["Setup & Sync"]
        XCTAssertTrue(setupBack.waitForExistence(timeout: 10))
        setupBack.tap()
        let privacy = app.buttons["Privacy & data"]
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

        let hostPill = app.buttons["harc.mobile.host.health"]
        XCTAssertTrue(hostPill.waitForExistence(timeout: 10))
        hostPill.tap()
        let advanced = app.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.tap()
        let openSample = app.buttons["harc.mobile.reviewSample.open"]
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
        let setupBack = app.navigationBars["Advanced"]
            .buttons["Setup & Sync"]
        XCTAssertTrue(setupBack.waitForExistence(timeout: 10))
        setupBack.tap()
        let privacy = app.buttons["Privacy & data"]
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

    func testPhysicalLiveActivityStopsBackgroundRecording() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Background microphone and Live Activity require a physical iPhone.")
#else
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
        let app = makeApp(rootID: TestRoot.liveActivity)
        app.launch()
        let start = app.buttons["harc.mobile.record.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        triggerMicrophonePermissionMonitor(in: app)
        let stop = app.buttons["harc.mobile.record.stop"]
        defer {
            app.activate()
            if stop.waitForExistence(timeout: 2) { stop.tap() }
        }
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        _ = XCTWaiter.wait(
            for: [expectation(description: "persist microphone checkpoint")],
            timeout: 7
        )
        keepTideScreenshot("Tide-Physical-Recording")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 10),
            "Home must background Harc before the activity stop is exercised."
        )
        _ = XCTWaiter.wait(
            for: [expectation(description: "allow the compact activity to render")],
            timeout: 2
        )
        keepTideScreenshot("Tide-Physical-DynamicIsland")
        // Notification Center presents the Lock Screen activity without a
        // private lock-button API. Locked-device behavior remains a manual gate.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo:
                springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        let activityStop = springboard.buttons["Stop and save recording"]
        XCTAssertTrue(activityStop.waitForExistence(timeout: 15))
        let activityPermission = springboard.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Allow Live Activities from Harc Tide Test")
        ).firstMatch
        if activityPermission.exists, springboard.buttons["Allow"].exists {
            springboard.buttons["Allow"].tap()
        }
        XCTAssertTrue(
            springboard.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "audio saved")
            ).firstMatch.waitForExistence(timeout: 25),
            "The activity must show a durable checkpoint before stopping."
        )
        keepTideScreenshot("Tide-Physical-LiveActivity")
        activityStop.tap()
        app.activate()
        XCTAssertTrue(app.staticTexts["Saved locally"].waitForExistence(timeout: 15))
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
        static let liveActivity =
            "A6000000-0000-4000-8000-202610200001"
        static let accessibilityAudit =
            "A4000000-0000-4000-8000-202608090001"
        static let forceQuitRecovery =
            "C5000000-0000-4000-8000-202608090001"
        static let storageExhaustion =
            "C7000000-0000-4000-8000-202608090001"
    }

    private func keepTideScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private func scrollToHittableButton(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        // A sheet and its presenting Library can both expose this shared
        // component's identifier. Resolve the active control on each screen.
        let matches = app.buttons.matching(identifier: identifier)
        for _ in 0..<8 {
            if let button = matches.allElementsBoundByIndex.first(where: {
                $0.isEnabled && $0.isHittable
            }) { return button }
            app.swipeUp()
        }
        return matches.allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable }
    }

    private func recoveryDiagnostics(in app: XCUIApplication) -> String {
        let buttons = app.buttons.matching(identifier: "harc.mobile.library.refresh-setup")
            .allElementsBoundByIndex.map {
                "enabled=\($0.isEnabled), hittable=\($0.isHittable), frame=\($0.frame)"
            }
        let statuses = app.descendants(matching: .any)
            .matching(identifier: "harc.mobile.library.refresh-status")
            .allElementsBoundByIndex.map(\.label)
        return String("Setup recovery unavailable; buttons=\(buttons); statuses=\(statuses)".prefix(1000))
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
    func testLongHostNameKeepsRecordAndToolbarsUsable() {
        let name = "Fixture Mac mini — Design and Accessibility Review Workstation"
        var layoutFailures: [String] = []
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = makeApp(rootID: UUID().uuidString, additionalArguments: [
                "--harc-ui-test-long-host-name", "--harc-ui-test-cached-library",
                "-UIPreferredContentSizeCategoryName", category,
            ])
            app.launch()
            for tab in ["Record", "Library", "Search"] {
                if tab == "Search" {
                    let search = app.tabBars.buttons["Search"]
                    XCTAssertTrue(search.waitForExistence(timeout: 10))
                    XCTAssertTrue(search.isHittable)
                    search.tap()
                    // iOS can replace the selected Search tab button with
                    // its native search field. Verify the destination itself.
                    XCTAssertTrue(app.descendants(matching: .any)["harc.mobile.search"].waitForExistence(timeout: 10))
                    let searchField = app.searchFields["Search meetings and transcripts"]
                    XCTAssertTrue(searchField.waitForExistence(timeout: 10))
                    XCTAssertTrue(searchField.isHittable)
                } else if tab != "Record" {
                    selectTab(tab, in: app)
                }
                let host = app.buttons["harc.mobile.host.health"]
                XCTAssertTrue(host.waitForExistence(timeout: 10))
                XCTAssertEqual(host.label, "Mac connection")
                XCTAssertEqual(host.value as? String, "\(name), unavailable")
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "Long-host-\(tab)-\(category)"
                shot.lifetime = .keepAlways
                add(shot)
                XCTAssertTrue(host.isHittable)
                XCTAssertGreaterThanOrEqual(host.frame.height, 44)
                if !app.frame.contains(host.frame) {
                    layoutFailures.append("\(tab) \(category): host frame outside viewport \(host.frame)")
                }
                if tab != "Record", host.frame.height > 60 {
                    layoutFailures.append("\(tab) \(category): oversized toolbar host \(host.frame)")
                }
                host.tap()
                XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
                // The fixture changes presentation only; real pairing stays absent.
                XCTAssertTrue(app.buttons["Pair a Mac"].exists)
                app.buttons["Done"].tap()
                XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForNonExistence(timeout: 10))
                XCTAssertTrue(host.waitForExistence(timeout: 10))
                XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
                if tab == "Search" {
                    let searchField = app.searchFields["Search meetings and transcripts"]
                    XCTAssertTrue(searchField.waitForExistence(timeout: 10))
                    XCTAssertTrue(searchField.isEnabled)
                    XCTAssertTrue(searchField.isHittable)
                    searchField.tap()
                    searchField.typeText("fixture")
                    XCTAssertEqual(searchField.value as? String, "fixture")
                }
            }
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
        XCTAssertTrue(layoutFailures.isEmpty, layoutFailures.joined(separator: "\n"))
    }

    func testLibraryTextActionsHaveAccessibleContrast() throws {
        let app = makeApp(rootID: UUID().uuidString, additionalArguments: [
            "--harc-ui-test-cached-library",
        ])
        app.launch()
        defer { app.terminate() }
        selectTab("Library", in: app)
        let identifiers = ["harc.mobile.library.refresh-action", "harc.mobile.library.refresh-setup"]
        for identifier in identifiers {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library-text-action-contrast"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // This regression targets the confirmed text-action defect. Other audit
        // findings remain part of the separate full-screen accessibility review.
        var actionFindings: [String] = []
        try app.performAccessibilityAudit(for: .contrast) { issue in
            if let element = issue.element,
               identifiers.contains(element.identifier)
                || ["Refresh Library", "Setup & Sync", "All"].contains(element.label) {
                actionFindings.append("\(element.identifier) \(element.label): \(issue.compactDescription)")
            }
            return true
        }
        XCTAssertTrue(actionFindings.isEmpty, actionFindings.joined(separator: "\n"))
        let setup = app.buttons["harc.mobile.library.refresh-setup"]
        for _ in 0..<5 where !setup.isHittable { app.swipeUp() }
        XCTAssertTrue(setup.isHittable)
        setup.tap()
        XCTAssertTrue(app.navigationBars["Setup & Sync"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
    }

    func testLibraryDaySummaryRemainsReadableAtLargestText() {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = makeApp(rootID: UUID().uuidString, additionalArguments: [
                "--harc-ui-test-cached-library",
                "-UIPreferredContentSizeCategoryName", category,
            ])
            app.launch()
            selectTab("Library", in: app)
            let day = app.staticTexts["Today"]
            let count = app.staticTexts["0 recordings"]
            XCTAssertTrue(day.waitForExistence(timeout: 10))
            XCTAssertTrue(count.waitForExistence(timeout: 10))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Library-day-summary-\(category)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertFalse(count.frame.isEmpty)
            XCTAssertTrue(app.frame.contains(count.frame))
            if category == "UICTContentSizeCategoryAccessibilityXXXL" {
                // The old horizontal header squeezed the count into three lines
                // ("0", "record-", "ings"). Keep full-size readable text below the day.
                XCTAssertGreaterThanOrEqual(count.frame.minY, day.frame.maxY)
                XCTAssertEqual(count.frame.minX, day.frame.minX, accuracy: 2)
                XCTAssertLessThanOrEqual(count.frame.height, day.frame.height + 2)
            } else {
                XCTAssertGreaterThan(count.frame.minX, day.frame.maxX)
            }
            let attention = app.buttons["harc.mobile.library.attention"]
            XCTAssertTrue(attention.waitForExistence(timeout: 10))
            for _ in 0..<8 where !attention.isHittable { app.swipeUp() }
            XCTAssertTrue(attention.isHittable)
            attention.tap()
            XCTAssertTrue(app.navigationBars["Sending to Mac"].waitForExistence(timeout: 10))
            app.navigationBars["Sending to Mac"].buttons["Library"].tap()
            XCTAssertTrue(app.tabBars.buttons["Library"].isSelected)
            XCTAssertFalse(app.buttons["harc.mobile.record.stop"].exists)
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
    }

}
