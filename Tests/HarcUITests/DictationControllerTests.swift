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

@MainActor
private func makeController(
    prefs: HarcPreferences,
    recordingState: RecordingState = RecordingState(),
    paster: SpyPaster,
    transcript: String = "hello world"
) -> (DictationController, DictationState) {
    let state = DictationState()
    let controller = DictationController(
        state: state,
        recordingState: recordingState,
        prefs: prefs,
        recorderFactory: { StubRecorder(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")) },
        transcribe: { _ in transcript },
        paster: paster
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
