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
        let evidence = XCTAttachment(screenshot: app.screenshot())
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
        func waitForPicker(label: String) -> Bool {
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "exists == true AND enabled == true AND label CONTAINS %@",
                    label
                ),
                object: picker()
            )], timeout: 20) == .completed
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
        XCTAssertTrue(waitForPicker(label: "UI Voice Carol"), app.debugDescription)
        app.terminate()
        openInspector()
        XCTAssertTrue(picker().waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(waitForPicker(label: "UI Voice Carol"), app.debugDescription)
        picker().click()
        app.menuItems["Unassign"].click()
        XCTAssertTrue(waitForPicker(label: "Speaker 1"), app.debugDescription)
        picker().click()
        app.menuItems["UI Voice Carol"].click()
        XCTAssertTrue(waitForPicker(label: "UI Voice Carol"), app.debugDescription)
        let evidence = XCTAttachment(screenshot: app.screenshot())
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
