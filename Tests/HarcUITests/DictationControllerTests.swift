import Testing
import Foundation
import Combine
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
    var appName: String?
    /// When set, `insert` throws instead of recording.
    var insertError: Error?
    private(set) var inserted: [String] = []
    private(set) var copied: [String] = []
    init(frontmost: String?, appName: String? = nil) {
        self.frontmost = frontmost
        self.appName = appName
    }
    func frontmostBundleID() -> String? { frontmost }
    func frontmostAppName() -> String? { appName }
    func insert(_ text: String) async throws {
        if let insertError { throw insertError }
        inserted.append(text)
    }
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

@Suite("Dictation without a microphone")
@MainActor
struct DictationNoInputDeviceTests {
    /// A Mac with no input device — a Mac mini with nothing plugged in — used
    /// to reach the audio engine and fail there, surfacing "Audio engine
    /// failure: No microphone input is available. Check Harc's Microphone
    /// permission in S…" truncated into the HUD pill. Refuse up front instead.
    @Test("dictation refuses with a readable reason and never opens the recorder")
    func refusesWithoutInputDevice() async {
        let prefs = HarcPreferences.shared
        let paster = SpyPaster(frontmost: "com.apple.TextEdit")
        let (controller, state) = makeController(
            prefs: prefs,
            paster: paster,
            hasInputDevice: { false }
        )

        await controller.start()

        #expect(state.phase == DictationState.Phase.error("No microphone connected"))
        #expect(paster.inserted.isEmpty)
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
    ruleMode: (@MainActor (String?) -> DictationMode?)? = nil,
    transformColdModelName: ((DictationMode) async -> String?)? = nil,
    preloadTransformModel: ((DictationMode) async -> Void)? = nil,
    contextCapture: SpyContextCapture? = nil,
    micPermission: (() async -> DictationController.MicPermission)? = nil,
    // These tests drive dictation through a fake recorder, so the machine's
    // own audio hardware is irrelevant to them — and must not decide whether
    // they run. One test overrides this to cover the no-device path.
    hasInputDevice: @escaping @Sendable () -> Bool = { true },
    ensureDaemonReady: ((@escaping @MainActor () -> Void) async throws -> Void)? = nil,
    cancelConfirmThreshold: TimeInterval = 30,
    harcBundleID: String = "com.harc.test-suite"
) -> (DictationController, DictationState) {
    let state = DictationState()
    let spy = contextCapture ?? SpyContextCapture()
    // Prefs are backed by shared UserDefaults — normalize the insertion
    // behaviour so a prior test run's write can't leak into this one.
    prefs.dictationInsertsAtCursor = true
    let controller = DictationController(
        state: state,
        recordingState: recordingState,
        prefs: prefs,
        recorderFactory: { StubRecorder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")) },
        transcribe: { _ in transcript },
        paster: paster,
        activeMode: { activeMode },
        transform: transform,
        ruleMode: ruleMode ?? { _ in nil },
        transformColdModelName: transformColdModelName,
        preloadTransformModel: preloadTransformModel,
        captureContext: { spy.capture($0, $1) },
        micPermission: micPermission ?? { .granted },
        hasInputDevice: hasInputDevice,
        ensureDaemonReady: ensureDaemonReady,
        cancelConfirmThreshold: cancelConfirmThreshold,
        harcBundleID: harcBundleID
    )
    return (controller, state)
}

/// The `.done` outcome, when the state is in the delivery end-state.
@MainActor
private func doneOutcome(_ state: DictationState) -> DictationDeliveryOutcome? {
    if case .done(let outcome) = state.phase { return outcome }
    return nil
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
    @Test("happy path inserts transcript and lands in the inserted end-state")
    func happyPath() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor", appName: "TextEditor")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "the quick brown fox")

        await controller.start()
        #expect(state.phase == .listening)
        await controller.stopAndInsert()

        #expect(paster.inserted == ["the quick brown fox"])
        #expect(paster.copied.isEmpty)
        let outcome = doneOutcome(state)
        #expect(outcome?.kind == .inserted)
        #expect(outcome?.message == "Inserted into TextEditor")
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
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "sensitive text")

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted.isEmpty)
        #expect(paster.copied == ["sensitive text"])
        #expect(doneOutcome(state)?.kind == .copied)
    }

    @Test("empty transcript inserts nothing and says so")
    func emptyTranscript() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "   ")

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted.isEmpty)
        #expect(paster.copied.isEmpty)
        guard case .error(let message) = state.phase else {
            Issue.record("expected an error end-state, got \(state.phase)")
            return
        }
        #expect(message.contains("No speech detected"))
    }
}

// MARK: - Delivery outcomes

@Suite("DictationController delivery outcomes")
@MainActor
struct DictationDeliveryOutcomeTests {
    @Test("copy-only preference lands on the clipboard with a copied end-state")
    func copyOnlyPreference() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "to clipboard")
        prefs.dictationInsertsAtCursor = false
        // Shared UserDefaults — leave the default behind for other tests.
        defer { prefs.dictationInsertsAtCursor = true }

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.inserted.isEmpty)
        #expect(paster.copied == ["to clipboard"])
        let outcome = doneOutcome(state)
        #expect(outcome?.kind == .copied)
        #expect(outcome?.message == "Copied to clipboard")
        #expect(outcome?.needsAccessibility == false)
    }

    @Test("accessibility-denied insert falls back to copy and asks for the permission")
    func accessibilityDeniedFallback() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        paster.insertError = FrontmostAppPaster.PasteError.accessibilityDenied
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "trapped words")
        var askedForAccessibility = false
        controller.onNeedsAccessibility = { askedForAccessibility = true }
        var entries: [DictationHistoryEntry] = []
        controller.onDelivered = { entries.append($0) }

        await controller.start()
        await controller.stopAndInsert()

        // The words are never lost.
        #expect(paster.copied == ["trapped words"])
        let outcome = doneOutcome(state)
        #expect(outcome?.kind == .copied)
        #expect(outcome?.needsAccessibility == true)
        #expect(outcome?.message.contains("Accessibility") == true)
        #expect(askedForAccessibility)
        #expect(entries.first?.delivery == .copied)
    }

    @Test("generic paste failure copies with an honest message")
    func genericPasteFailure() async {
        struct Boom: Error {}
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor", appName: "TextEditor")
        paster.insertError = Boom()
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "words")

        await controller.start()
        await controller.stopAndInsert()

        #expect(paster.copied == ["words"])
        let outcome = doneOutcome(state)
        #expect(outcome?.kind == .copied)
        #expect(outcome?.needsAccessibility == false)
        #expect(outcome?.message.contains("paste failed") == true)
    }
}

// MARK: - Preflight & daemon readiness

@Suite("DictationController preflight")
@MainActor
struct DictationPreflightTests {
    @Test("denied mic permission surfaces an actionable error, capture never starts")
    func micDenied() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(
            prefs: prefs, paster: paster,
            micPermission: { .denied }
        )

        await controller.start()

        guard case .error(let message) = state.phase else {
            Issue.record("expected error, got \(state.phase)")
            return
        }
        #expect(message.contains("Microphone"))
    }

    @Test("hotkey release during the mic prompt aborts cleanly instead of racing")
    func releaseDuringMicPrompt() async throws {
        let prefs = HarcPreferences()
        prefs.dictationTriggerStyle = .pushToTalk
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let gate = AsyncGate()
        let (controller, state) = makeController(
            prefs: prefs, paster: paster,
            micPermission: { await gate.wait(); return .granted }
        )

        let startTask = Task { await controller.start() }
        try await waitUntil { state.phase == .requestingMic }
        // User releases the key while the permission prompt is up.
        controller.handleHotkey(.keyUp)
        await gate.open()
        await startTask.value

        #expect(state.phase == .idle)
        #expect(paster.inserted.isEmpty)
    }

    @Test("cold daemon surfaces the loading-model phase before transcribing")
    func coldDaemonShowsLoading() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var phases: [DictationState.Phase] = []
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "warm words",
            ensureDaemonReady: { onColdStart in onColdStart() }
        )
        let observation = state.$phase.sink { phases.append($0) }
        defer { observation.cancel() }

        await controller.start()
        await controller.stopAndInsert()

        #expect(phases.contains(.loadingModel))
        #expect(paster.inserted == ["warm words"])
    }
}

// MARK: - Cancel confirmation

@Suite("DictationController cancel confirmation")
@MainActor
struct DictationCancelConfirmTests {
    @Test("short sessions cancel immediately")
    func shortSessionCancels() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, cancelConfirmThreshold: 30
        )

        await controller.start()
        await controller.cancel()

        #expect(state.phase == .idle)
        #expect(!state.confirmingCancel)
    }

    @Test("long sessions arm a confirmation; the second cancel discards")
    func longSessionNeedsConfirm() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        // Threshold 0 = every session counts as long.
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, cancelConfirmThreshold: 0
        )

        await controller.start()
        try? await Task.sleep(for: .milliseconds(10))
        await controller.cancel()
        // First cancel arms the confirmation and keeps listening.
        #expect(state.phase == .listening)
        #expect(state.confirmingCancel)

        await controller.cancel()
        #expect(state.phase == .idle)
        #expect(!state.confirmingCancel)
    }

    @Test("stopping clears an armed cancel confirmation")
    func stopClearsConfirm() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "kept words",
            cancelConfirmThreshold: 0
        )

        await controller.start()
        try? await Task.sleep(for: .milliseconds(10))
        await controller.cancel()
        #expect(state.confirmingCancel)

        await controller.stopAndInsert()
        #expect(paster.inserted == ["kept words"])
        #expect(!state.confirmingCancel)
    }
}

/// Simple async gate for suspending a seam until the test releases it.
private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
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
        #expect(doneOutcome(state)?.kind == .inserted)
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
        // The raw-fallback notice is user-visible in the delivery end-state.
        let outcome = doneOutcome(state)
        #expect(outcome?.message.contains("Test LLM") == true)
        #expect(outcome?.message.contains("raw text") == true)
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

// MARK: - Per-app activation rules

@Suite("DictationController per-app rules")
@MainActor
struct DictationRuleModeTests {
    private let ruleMode = DictationMode(
        id: "test.rule", name: "Rule", symbolName: "bolt",
        postProcess: .llm, instruction: "Rewrite.",
        activationBundleIDs: ["com.example.texteditor"]
    )
    private let hotkeyMode = DictationMode(
        id: "test.hotkey", name: "Hotkey", symbolName: "keyboard",
        postProcess: .llm, instruction: "Shout."
    )

    @Test("a matching rule beats the persisted active mode")
    func ruleBeatsActive() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var transformedWith: [String] = []
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: DictationMode.builtIns[0],  // Raw — would skip transform
            transform: { text, mode, _ in
                transformedWith.append(mode.id)
                return text
            },
            ruleMode: { [ruleMode] bundleID in
                bundleID == "com.example.texteditor" ? ruleMode : nil
            }
        )

        await controller.start()
        // The chip shows the override, flagged as rule-activated.
        #expect(state.sessionModeOverride?.id == "test.rule")
        #expect(state.sessionModeViaRule)
        await controller.stopAndInsert()

        #expect(transformedWith == ["test.rule"])
        // Rules never touch the persisted active mode.
        #expect(prefs.activeDictationModeID != "test.rule")
    }

    @Test("a one-shot mode hotkey beats a matching rule")
    func hotkeyBeatsRule() async throws {
        let prefs = HarcPreferences()
        prefs.dictationTriggerStyle = .pushToTalk
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var transformedWith: [String] = []
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: DictationMode.builtIns[0],
            transform: { text, mode, _ in
                transformedWith.append(mode.id)
                return text
            },
            ruleMode: { [ruleMode] bundleID in
                bundleID == "com.example.texteditor" ? ruleMode : nil
            }
        )

        controller.handleModeHotkey(.keyDown, mode: hotkeyMode)
        try await waitUntil { state.phase == .listening }
        #expect(state.sessionModeOverride?.id == "test.hotkey")
        #expect(!state.sessionModeViaRule)
        await controller.stopAndInsert()

        #expect(transformedWith == ["test.hotkey"])
    }

    @Test("no rule match falls through to the active mode with no override shown")
    func noMatchUsesActive() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.unrelated")
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            ruleMode: { [ruleMode] bundleID in
                bundleID == "com.example.texteditor" ? ruleMode : nil
            }
        )

        await controller.start()
        #expect(state.sessionModeOverride == nil)
        #expect(!state.sessionModeViaRule)
        await controller.stopAndInsert()
        #expect(paster.inserted == ["hello"])
    }

    @Test("the rule mode is frozen at start — a frontmost change mid-session doesn't switch it")
    func ruleFrozenAtStart() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var transformedWith: [String] = []
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: DictationMode.builtIns[0],
            transform: { text, mode, _ in
                transformedWith.append(mode.id)
                return text
            },
            ruleMode: { [ruleMode] bundleID in
                bundleID == "com.example.texteditor" ? ruleMode : nil
            }
        )

        await controller.start()
        // The user switches apps while speaking.
        paster.frontmost = "com.example.unrelated"
        await controller.stopAndInsert()

        #expect(transformedWith == ["test.rule"])
    }
}

// MARK: - Store rule matching

@Suite("DictationModeStore activation rules")
@MainActor
struct DictationModeStoreRuleTests {
    @Test("mode(activatedBy:) matches by bundle id; nil and unknown ids don't")
    func matching() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-modes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictationModeStore(fileURL: url, prefs: HarcPreferences())

        var email = store.modes.first { $0.id == "builtin.email" }!
        email.activationBundleIDs = ["com.apple.mail"]
        store.update(email)

        #expect(store.mode(activatedBy: "com.apple.mail")?.id == "builtin.email")
        #expect(store.mode(activatedBy: "com.example.other") == nil)
        #expect(store.mode(activatedBy: nil) == nil)
        #expect(store.mode(activatedBy: "") == nil)
    }

    @Test("activation rules round-trip through persistence; legacy JSON decodes to no rules")
    func persistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-modes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let prefs = HarcPreferences()
        let store = DictationModeStore(fileURL: url, prefs: prefs)
        var bullets = store.modes.first { $0.id == "builtin.bullets" }!
        bullets.activationBundleIDs = ["com.apple.Notes"]
        store.update(bullets)

        let reloaded = DictationModeStore(fileURL: url, prefs: prefs)
        #expect(reloaded.mode(activatedBy: "com.apple.Notes")?.id == "builtin.bullets")

        // Pre-rules JSON (no activationBundleIDs key) still decodes.
        let legacy = """
        [{"id":"legacy.mode","name":"Legacy","symbolName":"star","postProcess":"llm",
          "instruction":"Do things.","isBuiltIn":false}]
        """
        let decoded = try JSONDecoder().decode([DictationMode].self, from: Data(legacy.utf8))
        #expect(decoded[0].activationBundleIDs.isEmpty)
    }
}

// MARK: - Cold LLM load phase

@Suite("DictationController transform cold-load")
@MainActor
struct DictationColdLoadTests {
    private let llmMode = DictationMode(
        id: "test.llm", name: "Rewrite", symbolName: "wand.and.stars",
        postProcess: .llm, instruction: "Rewrite."
    )

    @Test("a cold model shows the loading phase and preloads before transforming")
    func coldLoadSequence() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var phasesAtPreload: [DictationState.Phase] = []
        var preloadedBeforeTransform = false
        var preloadCount = 0
        var stateRef: DictationState?
        let (controller, state) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: llmMode,
            transform: { text, _, _ in
                preloadedBeforeTransform = preloadCount == 1
                return text.uppercased()
            },
            transformColdModelName: { _ in "Standard" },
            preloadTransformModel: { _ in
                preloadCount += 1
                if let stateRef { phasesAtPreload.append(stateRef.phase) }
            }
        )
        stateRef = state

        await controller.start()
        await controller.stopAndInsert()

        #expect(preloadCount == 1)
        #expect(phasesAtPreload == [.loadingTransformModel("Standard")])
        #expect(preloadedBeforeTransform)
        #expect(paster.inserted == ["HELLO"])
    }

    @Test("a warm model skips the loading phase entirely")
    func warmSkipsLoadingPhase() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor")
        var preloadCount = 0
        let (controller, _) = makeController(
            prefs: prefs, paster: paster, transcript: "hello",
            activeMode: llmMode,
            transform: { text, _, _ in text },
            transformColdModelName: { _ in nil },
            preloadTransformModel: { _ in preloadCount += 1 }
        )

        await controller.start()
        await controller.stopAndInsert()
        #expect(preloadCount == 0)
    }
}

// MARK: - Deep-link security (harc://dictate)

@Suite("DictationDeepLinkSecurity")
@MainActor
struct DictationDeepLinkSecurityTests {
    @Test("a deep link from another app never opens the mic — it arms a confirmation")
    func linkArmsConfirmationInsteadOfStarting() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.apple.Safari", appName: "Safari")
        let (controller, state) = makeController(prefs: prefs, paster: paster)

        controller.requestDeepLinkDictation(oneShot: nil)
        await Task.yield()

        #expect(state.pendingDeepLink != nil)
        #expect(state.pendingDeepLink?.requesterBundleID == "com.apple.Safari")
        #expect(state.pendingDeepLink?.requesterName == "Safari")
        #expect(!state.isActive, "the mic must not open on a bare URL")
    }

    @Test("confirmed link starts, but insertion refuses the requesting app — copy-only")
    func neverInsertsIntoDeliverer() async throws {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.apple.Safari", appName: "Safari")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "attack payload")

        controller.requestDeepLinkDictation(oneShot: nil)
        controller.confirmPendingDeepLink()
        try await waitUntil { state.isActive }
        #expect(state.pendingDeepLink == nil)

        // Safari (the requester) is still frontmost at stop time.
        await controller.stopAndInsert()

        #expect(paster.inserted.isEmpty, "transcript must never reach the app that fired the link")
        #expect(paster.copied == ["attack payload"])
        let outcome = doneOutcome(state)
        #expect(outcome?.kind == .copied)
        #expect(outcome?.message.contains("not inserted into Safari") == true)
    }

    @Test("confirmed link inserts normally once the user has moved to another app")
    func insertsWhenRequesterNoLongerFrontmost() async throws {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.apple.Safari", appName: "Safari")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "meeting notes")

        controller.requestDeepLinkDictation(oneShot: nil)
        controller.confirmPendingDeepLink()
        try await waitUntil { state.isActive }

        paster.frontmost = "com.example.texteditor"
        paster.appName = "TextEditor"
        await controller.stopAndInsert()

        #expect(paster.inserted == ["meeting notes"])
        #expect(doneOutcome(state)?.kind == .inserted)
    }

    @Test("a second link during a link-initiated session cancels — no insert, ever")
    func secondLinkCancels() async throws {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.apple.Safari", appName: "Safari")
        var delivered = 0
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "secret audio")
        controller.onDelivered = { _ in delivered += 1 }

        controller.requestDeepLinkDictation(oneShot: nil)
        controller.confirmPendingDeepLink()
        try await waitUntil { state.isActive }

        controller.requestDeepLinkDictation(oneShot: nil)
        try await waitUntil { !state.isActive }

        #expect(state.phase == .idle)
        #expect(paster.inserted.isEmpty)
        #expect(paster.copied.isEmpty)
        #expect(delivered == 0, "a cancelled link session records no history")
    }

    @Test("a link during a user-initiated session is ignored")
    func linkCannotEndUserSession() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.example.texteditor", appName: "TextEditor")
        let (controller, state) = makeController(prefs: prefs, paster: paster)

        await controller.start()
        #expect(state.phase == .listening)

        controller.requestDeepLinkDictation(oneShot: nil)
        await Task.yield()

        #expect(state.phase == .listening, "a webpage must not be able to end the user's dictation")
        #expect(state.pendingDeepLink == nil)
    }

    @Test("link fired while Harc is frontmost starts without confirmation")
    func harcFrontmostSkipsConfirmation() async throws {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.harc.test-suite", appName: "Harc")
        let (controller, state) = makeController(prefs: prefs, paster: paster)

        controller.requestDeepLinkDictation(oneShot: nil)
        try await waitUntil { state.isActive }

        #expect(state.phase == .listening)
        #expect(state.pendingDeepLink == nil)
    }

    @Test("dismissing the confirmation clears it without starting")
    func dismissClearsPending() async {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.apple.Safari", appName: "Safari")
        let (controller, state) = makeController(prefs: prefs, paster: paster)

        controller.requestDeepLinkDictation(oneShot: nil)
        #expect(state.pendingDeepLink != nil)
        controller.dismissPendingDeepLink()

        #expect(state.pendingDeepLink == nil)
        #expect(!state.isActive)
    }

    @Test("a hotkey session after an abandoned link session never inherits its origin")
    func staleOriginNeverLeaksIntoHotkeySession() async throws {
        let prefs = HarcPreferences()
        let paster = SpyPaster(frontmost: "com.apple.Safari", appName: "Safari")
        let (controller, state) = makeController(prefs: prefs, paster: paster, transcript: "normal text")

        // Link session starts and is cancelled.
        controller.requestDeepLinkDictation(oneShot: nil)
        controller.confirmPendingDeepLink()
        try await waitUntil { state.isActive }
        await controller.cancel(bypassConfirm: true)
        #expect(!state.isActive)

        // A plain hotkey session into Safari must insert normally.
        await controller.start()
        #expect(state.phase == .listening)
        await controller.stopAndInsert()

        #expect(paster.inserted == ["normal text"])
        #expect(doneOutcome(state)?.kind == .inserted)
    }
}
