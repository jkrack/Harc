import AppKit
import XCTest

final class HarcAppUITests: XCTestCase {
    private var app: XCUIApplication!
    private var rootURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-app-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        app = XCUIApplication()
        app.launchEnvironment["HARC_UI_TESTING"] = "1"
        app.launchEnvironment["HARC_UI_TEST_ROOT"] = rootURL.path
        app.launchEnvironment["HARC_UI_TEST_SEED_LIBRARY"] = "1"
        app.launchEnvironment["HARC_UI_TEST_OPEN_LIBRARY"] = "1"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        app = nil
        rootURL = nil
    }

    /// Separate cases bound screenshot memory and scratch audio per appearance.
    func testTideFidelityStateMatrixDark() throws {
        try captureTideMatrix(appearance: "dark")
    }

    func testTideFidelityStateMatrixLight() throws {
        try captureTideMatrix(appearance: "light")
    }

    private func captureTideMatrix(appearance: String) throws {
        let states = ["complete", "untitled", "zero", "short", "integrity", "origins", "live", "short-day", "empty"]
        for state in states {
            try autoreleasepool {
                try captureTideState(state, appearance: appearance)
            }
        }
    }

    private func captureTideState(_ state: String, appearance: String) throws {
        app.terminate()
        let fixtureRoot = rootURL.appendingPathComponent("\(state)-\(appearance)")
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        app.launchEnvironment["HARC_UI_TEST_ROOT"] = fixtureRoot.path
        app.launchEnvironment["HARC_UI_TEST_APPEARANCE"] = appearance
        app.launchEnvironment["HARC_UI_TEST_LIBRARY_STATE"] = state
        app.launchEnvironment["HARC_UI_TEST_FAKE_RECORDING"] = "1"
        app.launch()
        XCTAssertTrue(app.searchFields["harc.library.search"].waitForExistence(timeout: 60), app.debugDescription)
        app.activate() // Window screenshots otherwise include an occluding app in an empty fixture.
        if state == "live" {
            app.buttons["harc.library.capture.recordButton"].click()
            XCTAssertTrue(app.descendants(matching: .any)["harc.library.liveRow"].waitForExistence(timeout: 10))
        } else if state != "empty" {
            let row = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "harc.library.recording.")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 60), app.debugDescription)
            row.click()
            if ["complete", "integrity", "origins"].contains(state) {
                XCTAssertTrue(staticText(containing: "Talk time").waitForExistence(timeout: 20), app.debugDescription)
                XCTAssertTrue(app.descendants(matching: .any)["harc.player.waveform.ready"].waitForExistence(timeout: 60), app.debugDescription)
            }
        }
        if state == "untitled" {
            XCTAssertTrue(app.descendants(matching: .any)["harc.player.waveform.ready"].waitForExistence(timeout: 60), app.debugDescription)
        } else if state == "short" {
            XCTAssertTrue(staticText(containing: "Less than a second of audio").waitForExistence(timeout: 10), app.debugDescription)
        } else if state == "short-day" {
            XCTAssertTrue(staticText(containing: "1 second of audio").waitForExistence(timeout: 10), app.debugDescription)
        } else if state == "empty" {
            let message = app.staticTexts["Ready for your first recording"]
            XCTAssertTrue(message.waitForExistence(timeout: 10), app.debugDescription)
            message.click() // Raise the agent app without focusing the search field.
        }
        if ["untitled", "zero", "short", "short-day"].contains(state) {
            XCTAssertTrue(staticText(containing: "No transcript available").waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.buttons["Generate"].exists, app.debugDescription)
        }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "fidelity-mac-\(state)-\(appearance)"
        shot.lifetime = .keepAlways
        add(shot)
        if state == "short-day" {
            let list = app.scrollViews.firstMatch
            list.swipeUp()
            let scrolled = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            scrolled.name = "fidelity-mac-short-day-scrolled-\(appearance)"
            scrolled.lifetime = .keepAlways
            add(scrolled)
        }
        if state == "origins" {
            // A row identifier is inherited by every child text element.
            let phone = app.outlines.staticTexts.matching(NSPredicate(
                format: "label == %@ OR value == %@", "James’s iPhone", "James’s iPhone"
            )).firstMatch
            XCTAssertTrue(phone.waitForExistence(timeout: 10), app.debugDescription)
            phone.click()
            XCTAssertTrue(staticText(containing: "Recorded on James’s iPhone").waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.descendants(matching: .any)["harc.player.waveform.ready"].waitForExistence(timeout: 60), app.debugDescription)
            let origin = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            origin.name = "fidelity-mac-origin-second-\(appearance)"
            origin.lifetime = .keepAlways
            add(origin)
        }
    }

    func testPlaybackControlsSeekAndPause() throws {
        app.launchEnvironment["HARC_UI_TEST_LIBRARY_STATE"] = "complete"
        app.launch()
        let row = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "harc.library.recording.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.click()
        let waveform = app.descendants(matching: .any)["harc.player.waveform.ready"]
        XCTAssertTrue(waveform.waitForExistence(timeout: 60))
        // The macOS waveform AX node is an adjustable Other without a textual
        // value. Read the visible, named elapsed control for every seek surface.
        let elapsed = app.staticTexts["harc.player.elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let playPause = app.buttons["harc.player.playPause"]
        XCTAssertEqual(playPause.label, "Play recording")
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != nil AND NOT value BEGINSWITH %@", "0:00 / "),
            object: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        assertPlaybackPosition(elapsed, fraction: 0.5)
        XCTAssertEqual(playPause.label, "Play recording", "Seeking paused audio must not start it")
        playPause.click()
        XCTAssertTrue(app.buttons["Pause recording"].waitForExistence(timeout: 5))
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        assertPlaybackPosition(elapsed, fraction: 0.3)
        XCTAssertEqual(playPause.label, "Pause recording", "Seeking playing audio must keep playing")
        playPause.click()
        XCTAssertTrue(app.buttons["Play recording"].waitForExistence(timeout: 5))
        let start = waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        assertPlaybackPosition(elapsed, fraction: 0.7)
        XCTAssertEqual(playPause.label, "Play recording")
        let strip = app.descendants(matching: .any)["harc.player.speakerStrip"]
        XCTAssertTrue(strip.exists)
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        assertPlaybackPosition(elapsed, fraction: 0.25)
        XCTAssertEqual(playPause.label, "Play recording")
        app.buttons["Speakers"].click()
        let speakers = app.descendants(matching: .any)["harc.player.speakers"]
        XCTAssertTrue(speakers.waitForExistence(timeout: 5))
        speakers.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        assertPlaybackPosition(elapsed, fraction: 0.6)
        XCTAssertEqual(playPause.label, "Play recording")
        app.buttons["Energy"].click()
        let editor = app.textViews["harc.transcript.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        // First line's speaker label is deliberately not a timed word.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 20)).click()
        assertPlaybackPosition(elapsed, fraction: 0)
        XCTAssertEqual(playPause.label, "Play recording")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Playback controls after transcript seek"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertPlaybackPosition(_ element: XCUIElement, fraction: Double,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let expected = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = element.value as? String else { return false }
            let times = value.components(separatedBy: " / ").map { time in
                time.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            }
            return times.count == 2 && times[1] > 0 && abs(times[0] / times[1] - fraction) < 0.03
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: expected, object: element)],
                                     timeout: 5), .completed,
                       "Expected playback fraction \(fraction); elapsed value: \(String(describing: element.value))",
                       file: file, line: line)
    }

    func testCaptureIntegrityWarningSurvivesRelaunch() throws {
        app.launchEnvironment["HARC_UI_TEST_CAPTURE_ISSUE"] = "1"
        launchFixtureLibrary()
        XCTAssertTrue(staticText(containing: "UI Test Customer Renewal").exists)
        let warning = app.descendants(matching: .any)
            .matching(identifier: "harc.recording.captureIntegrityWarning").firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 8), app.debugDescription)
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "HARC_UI_TEST_CAPTURE_ISSUE")
        launchFixtureLibrary()
        XCTAssertTrue(staticText(containing: "UI Test Customer Renewal").exists)
        XCTAssertTrue(warning.waitForExistence(timeout: 8), app.debugDescription)
        let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        evidence.name = "Capture warning after relaunch"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testLaunchOpensFixtureLibraryAndShowsRecordingDetail() throws {
        launchFixtureLibrary()

        let recording = seededRecordingRow()
        XCTAssertTrue(recording.waitForExistence(timeout: 8), app.debugDescription)
        recording.click()

        XCTAssertTrue(staticText(containing: "UI Test Customer Renewal").waitForExistence(timeout: 2))
        XCTAssertTrue(staticText(containing: "pricing risk").waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(staticText(containing: "send the renewal plan").waitForExistence(timeout: 4), app.debugDescription)
    }

    func testTideLibraryCompositionInBothAppearances() throws {
        for appearance in ["dark", "light"] {
            app.launchEnvironment["HARC_UI_TEST_APPEARANCE"] = appearance
            launchFixtureLibrary()
            let recording = seededRecordingRow()
            XCTAssertTrue(recording.waitForExistence(timeout: 8), app.debugDescription)
            recording.click()
            XCTAssertTrue(app.searchFields["harc.library.search"].waitForExistence(timeout: 4))
            XCTAssertTrue(staticText(containing: "Talk time").waitForExistence(timeout: 4), app.debugDescription)
            XCTAssertTrue(staticText(containing: "Action items").waitForExistence(timeout: 4), app.debugDescription)
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Tide Library – \(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    func testLibrarySearchFindsRecordingByTitleAndTranscript() throws {
        launchFixtureLibrary()
        let searchField = app.searchFields.firstMatch
        searchField.click()
        app.typeText("Customer Renewal")
        XCTAssertTrue(searchResultText(containing: "UI Test Customer Renewal").waitForExistence(timeout: 6), app.debugDescription)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("pricing risk")
        XCTAssertEqual(searchField.value as? String, "pricing risk", app.debugDescription)
        XCTAssertTrue(searchResultText(containing: "pricing risk").waitForExistence(timeout: 6), app.debugDescription)
        searchField.buttons["cancel"].click()
        searchField.click()
        app.typeText("no-such-recording-82941")
        XCTAssertTrue(searchResultText(containing: "No Results").waitForExistence(timeout: 6), app.debugDescription)
        searchField.buttons["cancel"].click()
        searchField.click()
        XCTAssertTrue(seededRecordingRow().waitForExistence(timeout: 6), app.debugDescription)
    }

    func testSettingsCanOpenFromLibrary() throws {
        launchFixtureLibrary()

        // The sidebar no longer carries an "Open Settings" link — that was
        // onboarding copy shipped as permanent chrome. The canonical route
        // is the standard shortcut, which exercises the SwiftUI Settings
        // scene (the path that once crashed on the Transcription pane).
        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(app.windows["Harc Settings"].waitForExistence(timeout: 6) || app.windows["Settings"].waitForExistence(timeout: 6) || app.windows["General"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 4))
    }

    func testSettingsCanOpenAfterLibraryIsClosedAndReopened() throws {
        launchFixtureLibrary()

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 4), app.debugDescription)

        // Reopen through the resident status item's actual Library command.
        // XCUIApplication.activate() only foregrounds the process; it does
        // not guarantee delivery of an application-reopen event.
        let statusItem = app.menuBars.element(boundBy: 1).children(matching: .any).firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 4), app.debugDescription)
        statusItem.click()
        let libraryButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Library")).firstMatch
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 4), app.debugDescription)
        libraryButton.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8), app.debugDescription)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            app.windows["Harc Settings"].waitForExistence(timeout: 6)
                || app.windows["Settings"].waitForExistence(timeout: 6)
                || app.windows["General"].waitForExistence(timeout: 6),
            app.debugDescription
        )
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 4))
    }

    func testDockReopenKeepsRegularAppAndReturnsToLibrary() throws {
        // Let the target create this fixture. A UI runner's private container
        // temporary directory is not an accessible Library root for the app.
        try FileManager.default.removeItem(at: rootURL)
        rootURL = URL(fileURLWithPath: "/tmp/harc-dock-ui-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["HARC_UI_TEST_ROOT"] = rootURL.path
        launchFixtureLibrary()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let running = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertTrue(running.bundleIdentifier?.hasPrefix("com.harc.Harc") == true)
        let bundleURL = try XCTUnwrap(running.bundleURL)
        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 4))
            XCTAssertFalse(running.isTerminated)
            XCTAssertEqual(running.activationPolicy, .regular)
            // Launch Services sends the reopen event used by the Dock. Merely
            // activating XCUIApplication would not exercise the delegate.
            let reopened = expectation(description: "Launch Services reopen")
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: .init()) { _, error in
                XCTAssertNil(error)
                reopened.fulfill()
            }
            wait(for: [reopened], timeout: 10)
            XCTAssertTrue(app.searchFields["harc.library.search"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        }
        // Settings remaining visible must not suppress the Library reopen.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 4))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 6))
        let reopened = expectation(description: "Reopen with Settings visible")
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: .init()) { _, error in
            XCTAssertNil(error)
            reopened.fulfill()
        }
        wait(for: [reopened], timeout: 10)
        let search = app.searchFields["harc.library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.click()
        app.typeText("Dock reopen")
        XCTAssertEqual(search.value as? String, "Dock reopen")
    }

    func testLibraryOwnsMenusAfterRepeatedCloseAndReopen() throws {
        launchFixtureLibrary()
        for _ in 0..<3 {
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), app.debugDescription)
            let menu = app.menuBars.firstMatch
            XCTAssertTrue(menu.menuBarItems["Edit"].exists, app.debugDescription)
            XCTAssertTrue(menu.menuBarItems["File"].exists, app.debugDescription)
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 4), app.debugDescription)
            let statusItem = app.menuBars.element(boundBy: 1).children(matching: .any).firstMatch
            XCTAssertTrue(statusItem.waitForExistence(timeout: 4), app.debugDescription)
            statusItem.click()
            let library = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Library")).firstMatch
            XCTAssertTrue(library.waitForExistence(timeout: 4), app.debugDescription)
            library.click()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            // Do not call activate() here: that would hide a failed handoff.
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), app.debugDescription)
            let search = app.searchFields.firstMatch
            search.click()
            app.typeText("Customer")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Renewal")
            XCTAssertEqual(search.value as? String, "Renewal", app.debugDescription)
        }
    }

    func testTranscriptEditingPreservesSpecialCharactersAcrossRelaunch() throws {
        launchFixtureLibrary()
        let editor = app.textViews["harc.transcript.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        let markdown = """
        # Typed Markdown Gauntlet

        This paragraph types **bold**, *italic*, ***bold italic***, `inline code`, ~~strikethrough~~, [[Michelle]], @amy, @[Amy Williams], @person[Amy Williams], and @project[Q3 Launch].

        Symbols: ~ ! @ # $ % ^ & * ( ) _ + - = { } [ ] | \\ : ; " ' < > , . ? /
        Escaped: \\*literal asterisk\\* \\[literal brackets\\] \\`literal tick\\`

        - First typed bullet
        * Star typed bullet
        1. First typed ordered item
        - [ ] Typed unchecked task
        - [x] Typed checked task

        > Typed quote should render as a quote.

        ```swift
        let typed = "markdown"
        print(typed)
        ```

        | Field | Expected |
        | --- | --- |
        | Bullet | Created from dash space |

        ---

        [Typed Link](https://github.com/jkrack/Harc)
        """

        app.typeText(markdown)
        XCTAssertEqual(editor.value as? String, markdown, app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertNotEqual(editor.value as? String, markdown)
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(editor.value as? String, markdown, app.debugDescription)

        XCTAssertTrue(textView(containing: "- First typed bullet").waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(textView(containing: "Symbols: ~ ! @ # $ % ^ & *").waitForExistence(timeout: 4), app.debugDescription)

        // The current Library edits the transcript in place and autosaves.
        XCTAssertNotNil(waitForFile(pathExtension: "md", containing: markdown))
        app.terminate()
        launchFixtureLibrary()
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(editor.value as? String, markdown, app.debugDescription)
    }

    func testUndoAfterAutosaveRestoresPersistedTranscript() throws {
        launchFixtureLibrary()
        let editor = app.textViews["harc.transcript.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        let original = try XCTUnwrap(editor.value as? String)
        let replacement = "A saved edit that will be undone."
        editor.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(replacement)
        XCTAssertNotNil(waitForFile(pathExtension: "md", containing: replacement))

        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, original, app.debugDescription)
        XCTAssertNotNil(waitForFile(pathExtension: "md", containing: original))
        app.terminate()
        launchFixtureLibrary()
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(editor.value as? String, original, app.debugDescription)
    }

    func testBoundSpeakerCreateUnassignAndRelinkSurviveRelaunch() throws {
        app.launchEnvironment["HARC_UI_TEST_BOUND_SPEAKERS"] = "1"
        func openInspector() {
            launchFixtureLibrary()
            seededRecordingRow().click()
            let inspector = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] %@", "Inspector")).firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 4), app.debugDescription)
            inspector.click()
        }
        func picker() -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "harc.speaker.0.picker").firstMatch
        }
        func waitForPickerText(_ text: String, timeout: TimeInterval = 6) -> XCTWaiter.Result {
            let predicate = NSPredicate(
                format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@",
                text,
                text,
                text
            )
            return XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: predicate, object: picker())],
                timeout: timeout
            )
        }
        openInspector()
        XCTAssertTrue(picker().waitForExistence(timeout: 6), app.debugDescription)
        picker().click()
        app.menuItems["Add new person…"].click()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 4), app.debugDescription)
        name.click()
        name.typeText("UI Voice Carol")
        app.buttons["Add"].click()
        XCTAssertTrue(picker().waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertEqual(waitForPickerText("UI Voice Carol"), .completed, app.debugDescription)
        app.terminate()
        openInspector()
        XCTAssertTrue(picker().waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertEqual(waitForPickerText("UI Voice Carol"), .completed, app.debugDescription)
        picker().click()
        app.menuItems["Unassign"].click()
        // The picker always includes "Speaker 1:" even while assigned. Wait
        // for the actual unassigned state before capturing another review.
        let unassigned = NSPredicate(format: "label == %@", "Speaker 1: Assign person…")
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: unassigned, object: picker())],
            timeout: 6
        ), .completed, app.debugDescription)
        picker().click()
        app.menuItems["UI Voice Carol"].click()
        XCTAssertEqual(waitForPickerText("UI Voice Carol"), .completed, app.debugDescription)
        let evidence = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        evidence.name = "Bound speaker identity after relink"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testRecordingInspectorShowsSpeakersAndFiles() throws {
        launchFixtureLibrary()

        let recording = seededRecordingRow()
        XCTAssertTrue(recording.waitForExistence(timeout: 8), app.debugDescription)
        recording.click()

        let inspector = app.buttons
            .containing(NSPredicate(format: "label BEGINSWITH[c] %@", "Inspector"))
            .firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 4), app.debugDescription)
        inspector.click()

        XCTAssertTrue(app.staticTexts["Speakers"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.staticTexts["File"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(staticText(containing: "09-00-00.wav").waitForExistence(timeout: 4), app.debugDescription)
    }

    func testRecordStopPersistsGoldenTranscriptAcrossRelaunch() throws {
        let title = "UI Test Live Pipeline Review"
        let transcript = "Alyssa: Budget owner confirmed the launch checklist is complete. Marco: Send the customer recap by Friday and keep the renewal risk visible."
        app.launchEnvironment["HARC_UI_TEST_SEED_LIBRARY"] = "0"
        app.launchEnvironment["HARC_UI_TEST_FAKE_RECORDING"] = "1"
        app.launchEnvironment["HARC_UI_TEST_RECORDING_TITLE"] = title
        app.launchEnvironment["HARC_UI_TEST_RECORDING_TRANSCRIPT"] = transcript

        launchFixtureLibrary()

        let recordButton = app.buttons["harc.library.capture.recordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 8), app.debugDescription)
        recordButton.click()
        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(app.buttons["harc.library.capture.recordButton"].waitForExistence(timeout: 4), app.debugDescription)

        app.buttons["harc.library.capture.recordButton"].click()
        XCTAssertTrue(staticText(containing: title).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForFile(pathExtension: "md", containing: "Budget owner confirmed") != nil)
        XCTAssertTrue(waitForFile(pathExtension: "json", containing: "customer recap by Friday") != nil)

        let recording = seededRecordingRow()
        XCTAssertTrue(recording.waitForExistence(timeout: 6), app.debugDescription)
        recording.click()
        XCTAssertTrue(textView(containing: "Budget owner confirmed").waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(textView(containing: "renewal risk visible").waitForExistence(timeout: 6), app.debugDescription)

        let inspector = app.buttons
            .containing(NSPredicate(format: "label BEGINSWITH[c] %@", "Inspector"))
            .firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 4), app.debugDescription)
        inspector.click()

        app.terminate()
        launchFixtureLibrary()
        XCTAssertTrue(staticText(containing: title).waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(textView(containing: "Budget owner confirmed").waitForExistence(timeout: 8), app.debugDescription)
    }

    private func launchFixtureLibrary() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        // Launch opens the Library directly. Its window title follows the
        // selected recording; the former mode radio group no longer exists.
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    private func seededRecordingRow() -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", "harc.library.recording."))
            .firstMatch
    }

    private func searchResultText(containing text: String) -> XCUIElement {
        app.outlines.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text))
            .firstMatch
    }

    private func staticText(containing text: String) -> XCUIElement {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text))
            .firstMatch
    }

    private func textView(containing text: String) -> XCUIElement {
        app.textViews
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text))
            .firstMatch
    }

    private func waitForFile(pathExtension: String, containing text: String, timeout: TimeInterval = 10) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = file(pathExtension: pathExtension, containing: text) {
                return match
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return nil
    }

    private func file(pathExtension: String, containing text: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  contents.localizedCaseInsensitiveContains(text) else {
                continue
            }
            return url
        }
        return nil
    }
}
