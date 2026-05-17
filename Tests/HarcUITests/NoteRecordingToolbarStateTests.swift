import Testing
@testable import HarcUI

struct NoteRecordingToolbarStateTests {
    @Test("idle note can start recording into note")
    func idleCanStartRecordingIntoNote() {
        let state = NoteRecordingToolbarState.resolve(
            isRecording: false,
            activeNoteID: nil,
            currentNoteID: "note-a"
        )

        #expect(state == .idle)
        #expect(state.title == "Record into Note")
        #expect(state.canToggleDirectly == true)
    }

    @Test("active recording owned by this note can stop directly")
    func recordingOwnedByThisNoteCanStopDirectly() {
        let state = NoteRecordingToolbarState.resolve(
            isRecording: true,
            activeNoteID: "note-a",
            currentNoteID: "note-a"
        )

        #expect(state == .recordingIntoThisNote)
        #expect(state.title == "Stop Note Recording")
        #expect(state.canToggleDirectly == true)
    }

    @Test("active recording owned by another note cannot stop directly")
    func recordingOwnedByAnotherNoteCannotStopDirectly() {
        let state = NoteRecordingToolbarState.resolve(
            isRecording: true,
            activeNoteID: "note-b",
            currentNoteID: "note-a"
        )

        #expect(state == .recordingIntoAnotherNote)
        #expect(state.title == "Recording into Another Note")
        #expect(state.canToggleDirectly == false)
    }

    @Test("general recording cannot be stopped directly from note toolbar")
    func generalRecordingCannotStopDirectlyFromNoteToolbar() {
        let state = NoteRecordingToolbarState.resolve(
            isRecording: true,
            activeNoteID: nil,
            currentNoteID: "note-a"
        )

        #expect(state == .generalRecording)
        #expect(state.title == "General Recording Active")
        #expect(state.canToggleDirectly == false)
    }
}
