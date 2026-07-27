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

    func testLaunchOpensFixtureLibraryAndShowsRecordingDetail() throws {
        launchFixtureLibrary()

        let recording = app.staticTexts["UI Test Customer Renewal"]
        XCTAssertTrue(recording.waitForExistence(timeout: 8), app.debugDescription)
        recording.click()

        XCTAssertTrue(app.staticTexts["UI Test Customer Renewal"].waitForExistence(timeout: 2))
        XCTAssertTrue(staticText(containing: "pricing risk").waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(staticText(containing: "send the renewal plan").waitForExistence(timeout: 4), app.debugDescription)
    }

    func testLibrarySearchFindsSeededNoteAndRecording() throws {
        launchFixtureLibrary()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8), app.debugDescription)
        searchField.click()
        searchField.typeText("Michelle")

        XCTAssertTrue(app.staticTexts["Context Pack"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(app.staticTexts["UI Test Renewal Note"].waitForExistence(timeout: 4), app.debugDescription)
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

    func testWikiAndReviewModesShowSeededKnowledgeAndApproveProposal() throws {
        launchFixtureLibrary()

        switchMode("Wiki")
        XCTAssertTrue(app.staticTexts["UI Test Renewal Wiki"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(staticText(containing: "Friday follow-up").waitForExistence(timeout: 4), app.debugDescription)

        switchMode("Review")
        XCTAssertTrue(app.staticTexts["UI Test Renewal Proposal"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(staticText(containing: "durable renewal page").waitForExistence(timeout: 4), app.debugDescription)

        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 4), app.debugDescription)
        approve.click()
        XCTAssertTrue(staticText(containing: "Approved and written to Wiki").waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.buttons["Open Page"].waitForExistence(timeout: 4), app.debugDescription)
    }

    func testNoteEditorModesRenderSeededNote() throws {
        launchFixtureLibrary()

        if !app.windows["UI Test Renewal Note"].waitForExistence(timeout: 1) {
            let note = seededNoteRow()
            XCTAssertTrue(note.waitForExistence(timeout: 8), app.debugDescription)
            note.click()
        }

        XCTAssertTrue(app.windows["UI Test Renewal Note"].waitForExistence(timeout: 4) || app.textFields["Title"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Editor Mode"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(app.radioButtons["Live"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(staticText(containing: "Follow up with Michelle").waitForExistence(timeout: 4), app.debugDescription)

        app.radioButtons["Source"].click()
        XCTAssertTrue(app.radioButtons["Source"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(staticText(containing: "Follow up with Michelle").waitForExistence(timeout: 4), app.debugDescription)

        app.radioButtons["Read"].click()
        XCTAssertTrue(app.radioButtons["Read"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(staticText(containing: "Follow up with Michelle").waitForExistence(timeout: 4), app.debugDescription)
    }

    func testMarkdownTypingCoversListEntryAndSpecialCharacters() throws {
        launchFixtureLibrary()

        if !app.windows["UI Test Renewal Note"].waitForExistence(timeout: 1) {
            let note = seededNoteRow()
            XCTAssertTrue(note.waitForExistence(timeout: 8), app.debugDescription)
            note.click()
        }

        XCTAssertTrue(app.radioButtons["Source"].waitForExistence(timeout: 6), app.debugDescription)
        app.radioButtons["Source"].click()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeKey(.delete, modifierFlags: [])

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

        editor.typeText(markdown)

        XCTAssertTrue(textView(containing: "- First typed bullet").waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(textView(containing: "Symbols: ~ ! @ # $ % ^ & *").waitForExistence(timeout: 4), app.debugDescription)

        let save = app.buttons["Save Note"]
        if save.waitForExistence(timeout: 2), save.isEnabled {
            save.click()
        }

        XCTAssertNotNil(waitForFile(pathExtension: "md", containing: "- First typed bullet"))
        XCTAssertNotNil(waitForFile(pathExtension: "md", containing: "Symbols: ~ ! @ # $ % ^ & * ( ) _ + - = { } [ ] | \\ : ; \" ' < > , . ? /"))
        XCTAssertNotNil(waitForFile(pathExtension: "md", containing: "| Bullet | Created from dash space |"))

        app.radioButtons["Live"].click()
        XCTAssertTrue(waitForVisibleNoteText("First typed bullet", timeout: 6), app.debugDescription)
        XCTAssertTrue(waitForVisibleNoteText("Typed unchecked task", timeout: 6), app.debugDescription)
        XCTAssertTrue(waitForVisibleNoteText("Created from dash space", timeout: 6), app.debugDescription)

        app.radioButtons["Read"].click()
        XCTAssertTrue(waitForVisibleNoteText("First typed bullet", timeout: 6), app.debugDescription)
        XCTAssertTrue(waitForVisibleNoteText("Typed Link", timeout: 6), app.debugDescription)
    }

    func testRecordingInspectorShowsSpeakersLinkedNotesAndFiles() throws {
        launchFixtureLibrary()

        let recording = app.staticTexts["UI Test Customer Renewal"]
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
        XCTAssertTrue(staticText(containing: "UI Test Renewal Note").waitForExistence(timeout: 4), app.debugDescription)
    }

    func testRecordStopTranscribeCreateNoteLoopUsesGoldenOutput() throws {
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
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForFile(pathExtension: "txt", containing: "Budget owner confirmed") != nil)
        XCTAssertTrue(waitForFile(pathExtension: "json", containing: "customer recap by Friday") != nil)

        let recording = seededRecordingRow()
        XCTAssertTrue(recording.waitForExistence(timeout: 6), app.debugDescription)
        recording.click()
        XCTAssertTrue(staticText(containing: "Budget owner confirmed").waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(staticText(containing: "renewal risk visible").waitForExistence(timeout: 6), app.debugDescription)

        let inspector = app.buttons
            .containing(NSPredicate(format: "label BEGINSWITH[c] %@", "Inspector"))
            .firstMatch
        XCTAssertTrue(inspector.waitForExistence(timeout: 4), app.debugDescription)
        inspector.click()

        let newNote = app.buttons["New note from this recording"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 6), app.debugDescription)
        newNote.click()

        XCTAssertTrue(app.windows[title].waitForExistence(timeout: 6) || app.staticTexts["1 recording"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.staticTexts["1 recording"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(waitForFile(pathExtension: "md", containing: "recording:") != nil)
    }

    private func launchFixtureLibrary() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        switchMode("Library")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    private func switchMode(_ title: String) {
        let mode = app.radioButtons[title]
        XCTAssertTrue(mode.waitForExistence(timeout: 8), app.debugDescription)
        mode.click()
    }

    private func seededNoteRow() -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", "harc.library.note."))
            .firstMatch
    }

    private func seededRecordingRow() -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", "harc.library.recording."))
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

    private func waitForVisibleNoteText(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if staticText(containing: text).exists || textView(containing: text).exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
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
