import Testing
import Foundation
import HarcAudio
@testable import HarcUI

// MARK: - Test doubles

private actor StubRecorder: DictationRecording {
    nonisolated let levels: AsyncStream<Float>
    private let url: URL
    init(url: URL) {
        self.url = url
        self.levels = AsyncStream { $0.finish() }
    }
    func start() async throws {}
    func stop() async throws -> URL {
        try? Data("stub".utf8).write(to: url)
        return url
    }
    func cancel() async {}
}

@MainActor
private final class SpyPaster: DictationPasting {
    var frontmost: String?
    private(set) var inserted: [String] = []
    private(set) var copied: [String] = []
    init(frontmost: String?) { self.frontmost = frontmost }
    func frontmostBundleID() -> String? { frontmost }
    func insert(_ text: String) throws { inserted.append(text) }
    func copyOnly(_ text: String) { copied.append(text) }
}

/// Records context-capture invocations and returns a canned snapshot.
@MainActor
private final class SpyContextCapture {
    var result: DictationContext
    private(set) var calls: [(selectedText: Bool, clipboard: Bool)] = []
    init(result: DictationContext = .empty) { self.result = result }
    func capture(_ selectedText: Bool, _ clipboard: Bool) -> DictationContext {
        calls.append((selectedText, clipboard))
        return result
    }
}

@MainActor
private func makeController(
    prefs: HarcPreferences,
    recordingState: RecordingState = RecordingState(),
    paster: SpyPaster,
    transcript: String = "hello world",
    activeMode: DictationMode = DictationMode.builtIns[0],
    transform: ((String, DictationMode, String?) async throws -> String)? = nil,
    contextCapture: SpyContextCapture? = nil
) -> (DictationController, DictationState) {
    let state = DictationState()
    let spy = contextCapture ?? SpyContextCapture()
    let controller = DictationController(
        state: state,
        recordingState: recordingState,
        prefs: prefs,
        recorderFactory: { StubRecorder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")) },
        transcribe: { _ in transcript },
        paster: paster,
        activeMode: { activeMode },
        transform: transform,
        captureContext: { spy.capture($0, $1) }
    )
    return (controller, state)
}

// MARK: - Trigger routing

@Suite("DictationTriggerRouter")
struct DictationTriggerRouterTests {
    @Test("push-to-talk: keyDown starts, keyUp stops")
    func pushToTalk() {
        #expect(DictationTriggerRouter.action(style: .pushToTalk, event: .keyDown, isActive: false) == .start)
        #expect(DictationTriggerRouter.action(style: .pushToTalk, event: .keyDown, isActive: true) == DictationAction.none)
        #expect(DictationTriggerRouter.action(style: .pushToTalk, event: .keyUp, isActive: true) == .stop)
        #expect(DictationTriggerRouter.action(style: .pushToTalk, event: .keyUp, isActive: false) == DictationAction.none)
    }

    @Test("toggle: keyDown flips, keyUp is inert")
    func toggle() {
        #expect(DictationTriggerRouter.action(style: .toggle, event: .keyDown, isActive: false) == .start)
        #expect(DictationTriggerRouter.action(style: .toggle, event: .keyDown, isActive: true) == .stop)
        #expect(DictationTriggerRouter.action(style: .toggle, event: .keyUp, isActive: true) == DictationAction.none)
        #expect(DictationTriggerRouter.action(style: .toggle, event: .keyUp, isActive: false) == DictationAction.none)
    }
}

// MARK: - State

@Suite("DictationState")
@MainActor
struct DictationStateTests {
    @Test("isActive reflects phase; idle clears levels")
    func activeAndLevels() {
        let s = DictationState()
        #expect(s.isActive == false)
        s.setPhase(.listening)
        #expect(s.isActive)
        s.pushLevel(0.4)
        s.pushLevel(0.6)
        #expect(s.levelHistory == [0.4, 0.6])
        s.setPhase(.idle)
        #expect(s.isActive == false)
        #expect(s.levelHistory.isEmpty)
    }

    @Test("level history is capped")
    func levelCap() {
        let s = DictationState()
        for i in 0..<(DictationState.levelHistoryCount + 20) {
            s.pushLevel(Float(i))
        }
        #expect(s.levelHistory.count == DictationState.levelHistoryCount)
    }
}

// MARK: - Controller

@Suite("DictationController")
@MainActor
struct DictationControllerTests {
    @Test("happy path inserts transcript and returns to idle")
    func happyPath() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "the quick brown fox")

        await controller.start()
        #expect(state.phase == .listening)
        await controller.stopAndInsert()

        #expect(paster.inserted == ["the quick brown fox"])
        #expect(paster.copied.isEmpty)
        #expect(state.phase == .idle)
    }

    @Test("refuses to start while a meeting recording is active")
    func mutualExclusionMeetingBlocksDictation() async {
        let prefs = HarcPreferences()
        let recording = RecordingState()
        recording.markStarted(at: Date())
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var blocked = false
        let (controller, state) = makeController(prefs: prefs, recordingState: recording, paster: paster)
        controller.onBlockedByRecording = { blocked = true }

        await controller.start()

        #expect(state.isActive == false)
        #expect(blocked)
    }

    @Test("deny-listed target copies instead of pasting")
    func denyListGating() async {
        let prefs = HarcPreferences()
        prefs.addPasteDenyListBundleID("com.test.secret")
        let paster = SpyPaster(frontmost: "com.test.secret")
        let (controller, _) = makeController(prefs: prefs, paster: paster, transcript: "sensitive text")

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted.isEmpty)
        #expect(paster.copied == ["sensitive text"])
    }

    @Test("empty transcript inserts nothing")
    func emptyTranscript() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "   ")

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted.isEmpty)
        #expect(paster.copied.isEmpty)
        #expect(state.phase == .idle)
    }
}

// MARK: - Mode routing

@Suite("DictationController mode routing")
@MainActor
struct DictationModeRoutingTests {
    private let llmMode = DictationMode(
        id: "test.llm", name: "Test LLM", symbolName: "sparkles",
        postProcess: .llm, instruction: "Rewrite."
    )

    @Test("llm mode inserts the transformed text")
    func transformApplied() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "raw words",
            activeMode: llmMode,
            transform: { text, mode, _ in
                #expect(text == "raw words")
                #expect(mode.id == "test.llm")
                return "polished words"
            }
        )

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted == ["polished words"])
        #expect(state.notice == nil)
        #expect(state.phase == .idle)
    }

    @Test("transform failure falls back to raw text with a notice")
    func transformFailureFallsBack() async {
        struct Boom: Error {}
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "raw words",
            activeMode: llmMode,
            transform: { _, _, _ in throw Boom() }
        )

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted == ["raw words"])
        #expect(state.notice?.contains("Test LLM") == true)
        #expect(state.phase == .idle)
    }

    @Test("empty transform result falls back to raw text")
    func emptyTransformFallsBack() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, transcript: "raw words",
            activeMode: llmMode,
            transform: { _, _, _ in "  \n " }
        )

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted == ["raw words"])
    }

    @Test("raw mode never invokes the transform")
    func rawModeSkipsTransform() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, transcript: "raw words",
            activeMode: DictationMode.builtIns[0],  // Raw
            transform: { _, _, _ in
                Issue.record("transform must not run for raw mode")
                return "wrong"
            }
        )

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted == ["raw words"])
    }

    @Test("missing transform seam inserts raw for llm mode")
    func noTransformWired() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, transcript: "raw words",
            activeMode: llmMode,
            transform: nil
        )

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted == ["raw words"])
    }
}

// MARK: - Super Mode context capture

@Suite("DictationController context capture")
@MainActor
struct DictationContextCaptureTests {
    private let contextMode = DictationMode(
        id: "test.context", name: "Context", symbolName: "sparkles",
        postProcess: .llm, instruction: "Answer.",
        includeSelectedText: true, includeClipboard: true
    )

    @Test("captures at start with the mode's toggles and passes the block to transform")
    func capturesAtStart() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let spy = SpyContextCapture(result: DictationContext(
            selectedText: "chosen words", frontmostAppName: "TextEditor"
        ))
        var receivedBlock: String??
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "raw words",
            activeMode: contextMode,
            transform: { _, _, block in
                receivedBlock = block
                return "answered"
            },
            contextCapture: spy
        )

        await controller.start()
        // Captured at start, before any transcription happened.
        #expect(spy.calls.count == 1)
        #expect(spy.calls[0].selectedText)
        #expect(spy.calls[0].clipboard)
        #expect(state.context.selectedText == "chosen words")

        await controller.stopAndInsert()
        #expect(receivedBlock??.contains("chosen words") == true)
        // Session ended — context cleared.
        #expect(state.context.isEmpty)
    }

    @Test("selected-text-only mode requests only the selection")
    func partialToggles() async {
        var mode = contextMode
        mode.includeClipboard = false
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let spy = SpyContextCapture()
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, activeMode: mode,
            transform: { text, _, _ in text }, contextCapture: spy
        )

        await controller.start()
        #expect(spy.calls.count == 1)
        #expect(spy.calls[0].selectedText)
        #expect(spy.calls[0].clipboard == false)
        await controller.cancel()
    }

    @Test("modes without context toggles never capture")
    func noCaptureWhenModeOff() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let spy = SpyContextCapture()
        let (controller, state) = makeController(
            prefs: prefs, paster: paster,
            activeMode: DictationMode.builtIns[0],  // Raw
            contextCapture: spy
        )

        await controller.start()
        #expect(spy.calls.isEmpty)
        #expect(state.context.isEmpty)
        await controller.cancel()
    }

    @Test("deny-listed frontmost app skips capture entirely")
    func denyListedSkipsCapture() async {
        let prefs = HarcPreferences()
        prefs.addPasteDenyListBundleID("com.test.passwords")
        let paster = SpyPaster(frontmost: "com.test.passwords")
        let spy = SpyContextCapture(result: DictationContext(selectedText: "hunter2"))
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, activeMode: contextMode,
            contextCapture: spy
        )

        await controller.start()
        #expect(spy.calls.isEmpty)
        #expect(state.context.isEmpty)
        await controller.cancel()
    }

    @Test("cancel clears captured context")
    func cancelClearsContext() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let spy = SpyContextCapture(result: DictationContext(clipboardText: "copied"))
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, activeMode: contextMode,
            contextCapture: spy
        )

        await controller.start()
        #expect(state.context.clipboardText == "copied")
        await controller.cancel()
        #expect(state.context.isEmpty)
    }
}

// MARK: - Per-mode hotkeys (one-shot override)

@Suite("DictationController one-shot mode override")
@MainActor
struct DictationOneShotModeTests {
    private let overrideMode = DictationMode(
        id: "test.override", name: "Override", symbolName: "bolt",
        postProcess: .llm, instruction: "Shout."
    )

    @Test("mode hotkey runs the session with that mode without changing the active mode")
    func overrideAppliesForOneSession() async throws {
        let prefs = HarcPreferences()
        prefs.dictationTriggerStyle = .pushToTalk
        prefs.activeDictationModeID = DictationMode.rawID
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var transformedWith: [String] = []
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: DictationMode.builtIns[0],  // Raw — would skip transform
            transform: { text, mode, _ in
                transformedWith.append(mode.id)
                return text.uppercased()
            }
        )

        controller.handleModeHotkey(.keyDown, mode: overrideMode)
        // Hotkey routing hops through a Task — wait for listening.
        try await waitUntil { state.phase == .listening }
        await controller.stopAndInsert()

        #expect(transformedWith == ["test.override"])
        #expect(paster.inserted == ["HELLO"])
        // The persisted active mode is untouched.
        #expect(prefs.activeDictationModeID == DictationMode.rawID)
    }

    @Test("override is one-shot — the next plain session uses the active mode")
    func overrideDoesNotStick() async throws {
        let prefs = HarcPreferences()
        prefs.dictationTriggerStyle = .pushToTalk
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var transformCalls = 0
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: DictationMode.builtIns[0],  // Raw
            transform: { text, _, _ in transformCalls += 1; return text }
        )

        controller.handleModeHotkey(.keyDown, mode: overrideMode)
        try await waitUntil { state.phase == .listening }
        await controller.stopAndInsert()
        #expect(transformCalls == 1)

        // Plain start: raw mode again, no transform.
        await controller.start()
        await controller.stopAndInsert()
        #expect(transformCalls == 1)
        #expect(paster.inserted.count == 2)
    }

    @Test("cancel discards the override")
    func cancelDiscardsOverride() async throws {
        let prefs = HarcPreferences()
        prefs.dictationTriggerStyle = .pushToTalk
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var transformCalls = 0
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: DictationMode.builtIns[0],
            transform: { text, _, _ in transformCalls += 1; return text }
        )

        controller.handleModeHotkey(.keyDown, mode: overrideMode)
        try await waitUntil { state.phase == .listening }
        await controller.cancel()

        await controller.start()
        await controller.stopAndInsert()
        #expect(transformCalls == 0)
    }
}

// MARK: - History recording

@Suite("DictationController history")
@MainActor
struct DictationHistoryRecordingTests {
    @Test("delivered dictation reports a pasted entry with mode and target")
    func recordsPasted() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, _) = makeController(prefs: prefs, paster: paster, transcript: "note this")
        var entries: [DictationHistoryEntry] = []
        controller.onDelivered = { entries.append($0) }

        await controller.start()
        await controller.stopAndInsert()

        #expect(entries.count == 1)
        #expect(entries[0].text == "note this")
        #expect(entries[0].rawText == nil)   // raw mode: text IS the raw transcript
        #expect(entries[0].modeName == "Raw")
        #expect(entries[0].delivery == .pasted)
    }

    @Test("transformed dictation keeps the raw transcript alongside")
    func recordsRawAlongsideTransform() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let mode = DictationMode(
            id: "test.shout", name: "Shout", symbolName: "bolt",
            postProcess: .llm, instruction: "Shout."
        )
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, transcript: "quiet words",
            activeMode: mode,
            transform: { text, _, _ in text.uppercased() }
        )
        var entries: [DictationHistoryEntry] = []
        controller.onDelivered = { entries.append($0) }

        await controller.start()
        await controller.stopAndInsert()

        #expect(entries.count == 1)
        #expect(entries[0].text == "QUIET WORDS")
        #expect(entries[0].rawText == "quiet words")
        #expect(entries[0].modeName == "Shout")
    }

    @Test("deny-listed target records a copied entry")
    func recordsCopiedFallback() async {
        let prefs = HarcPreferences()
        prefs.addPasteDenyListBundleID("com.test.secret")
        let paster = SpyPaster(frontmost: "com.test.secret")
        let (controller, _) = makeController(prefs: prefs, paster: paster, transcript: "psst")
        var entries: [DictationHistoryEntry] = []
        controller.onDelivered = { entries.append($0) }

        await controller.start()
        await controller.stopAndInsert()

        #expect(entries.count == 1)
        #expect(entries[0].delivery == .copied)
    }

    @Test("cancelled sessions record nothing")
    func cancelRecordsNothing() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, _) = makeController(prefs: prefs, paster: paster, transcript: "never delivered")
        var entries: [DictationHistoryEntry] = []
        controller.onDelivered = { entries.append($0) }

        await controller.start()
        await controller.cancel()

        #expect(entries.isEmpty)
    }
}

/// Poll until `condition` holds (hotkey handlers hop through Tasks).
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("waitUntil timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
