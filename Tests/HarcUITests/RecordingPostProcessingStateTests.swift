import Testing
import Foundation
@testable import HarcUI

@Suite("RecordingPostProcessingState")
@MainActor
struct RecordingPostProcessingStateTests {
    @Test("initial state has no current recording")
    func initialIsIdle() {
        let s = RecordingPostProcessingState()
        #expect(s.current == nil)
    }

    @Test("begin sets phase to .identifying for the right ID")
    func beginSetsIdentifying() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 42)
        if case .identifying = s.current?.phase {
            #expect(s.current?.recordingID == 42)
        } else {
            Issue.record("expected .identifying, got \(String(describing: s.current?.phase))")
        }
    }

    @Test("succeed transitions to .done with speakerCount")
    func succeedTransitionsToDone() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 7)
        s.succeed(recordingID: 7, speakerCount: 3)
        if case .done(let n) = s.current?.phase {
            #expect(n == 3)
            #expect(s.current?.recordingID == 7)
        } else {
            Issue.record("expected .done(3), got \(String(describing: s.current?.phase))")
        }
    }

    @Test("succeed for a different recording is a no-op")
    func succeedForOtherIDIgnored() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 1)
        s.succeed(recordingID: 99, speakerCount: 5)
        if case .identifying = s.current?.phase {
            #expect(s.current?.recordingID == 1)
        } else {
            Issue.record("expected unchanged .identifying, got \(String(describing: s.current?.phase))")
        }
    }

    @Test("fail transitions to .failed with message")
    func failTransitionsToFailed() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 9)
        s.fail(recordingID: 9, message: "model crashed")
        if case .failed(let msg) = s.current?.phase {
            #expect(msg == "model crashed")
        } else {
            Issue.record("expected .failed, got \(String(describing: s.current?.phase))")
        }
    }

    @Test("clear nils current when matched")
    func clearNilsCurrent() {
        let s = RecordingPostProcessingState()
        s.begin(recordingID: 11)
        s.clear(recordingID: 11)
        #expect(s.current == nil)
    }
}
