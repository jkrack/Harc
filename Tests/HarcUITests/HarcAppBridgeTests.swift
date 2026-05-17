import Testing
@testable import HarcUI

@Suite("HarcAppBridge")
@MainActor
struct HarcAppBridgeTests {
    @Test("reportPaste publishes status and flash state")
    func reportPastePublishesStatusAndFlashState() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.reportPaste(.failure, message: "Copied. Paste failed.")

        #expect(bridge.pasteFlash == .failure)
        #expect(bridge.iconState.pasteFlash == .failure)
        #expect(bridge.pasteStatusMessage == "Copied. Paste failed.")
    }

    @Test("stop recovery state can be shown and cleared")
    func stopRecoveryStateCanBeShownAndCleared() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )
        let info = StopRecoveryInfo(
            title: "Finalization is still running",
            message: "Audio capture stopped.",
            cacheDirectoryPath: "/tmp/Harc/recordings"
        )

        bridge.showStopRecovery(info)
        #expect(bridge.stopRecovery == info)

        bridge.clearStopRecovery()
        #expect(bridge.stopRecovery == nil)
    }

    @Test("readiness state publishes menu bar preflight details")
    func readinessStatePublishesPreflightDetails() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.destinationReady = false
        bridge.destinationPath = "/Volumes/Missing/Harc"
        bridge.captureReadinessText = "Mic only; system audio needs permission"
        bridge.captureReadinessWarning = true
        bridge.sttReadinessText = "Local STT ready"
        bridge.summarizerReadinessText = "Standard not installed"
        bridge.summarizerReady = false

        #expect(bridge.destinationReady == false)
        #expect(bridge.destinationPath == "/Volumes/Missing/Harc")
        #expect(bridge.captureReadinessWarning == true)
        #expect(bridge.summarizerReadinessText == "Standard not installed")
    }

    @Test("note recording link success publishes confirmation state")
    func noteRecordingLinkSuccessPublishesConfirmationState() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.showNoteRecordingLinked(
            noteID: "note-1",
            recordingTitle: "Design review",
            recordingID: 42,
            wavPath: "/tmp/design.wav"
        )

        #expect(bridge.noteRecordingLinkFeedback?.noteID == "note-1")
        #expect(bridge.noteRecordingLinkFeedback?.status == .linked)
        #expect(bridge.noteRecordingLinkFeedback?.canOpenRecording == true)
        #expect(bridge.noteRecordingLinkFeedback?.canRevealFile == true)
        #expect(bridge.noteRecordingLinkFeedback?.message == "Linked Design review to this note.")
    }

    @Test("note recording missing saved id publishes recovery state")
    func noteRecordingMissingSavedIDPublishesRecoveryState() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.showNoteRecordingMissingSavedID(
            noteID: "note-2",
            recordingTitle: "Planning",
            wavPath: "/tmp/planning.wav"
        )

        #expect(bridge.noteRecordingLinkFeedback?.status == .recoveryNeeded)
        #expect(bridge.noteRecordingLinkFeedback?.recordingID == nil)
        #expect(bridge.noteRecordingLinkFeedback?.canOpenRecording == true)
        #expect(bridge.noteRecordingLinkFeedback?.message.contains("could not find its Library ID") == true)
    }

    @Test("note recording link failure publishes recovery actions")
    func noteRecordingLinkFailurePublishesRecoveryActions() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.showNoteRecordingLinkFailed(
            noteID: "note-3",
            recordingTitle: "Retro",
            recordingID: 99,
            wavPath: "/tmp/retro.wav",
            errorDescription: "Note is read-only"
        )

        #expect(bridge.noteRecordingLinkFeedback?.status == .recoveryNeeded)
        #expect(bridge.noteRecordingLinkFeedback?.recordingID == 99)
        #expect(bridge.noteRecordingLinkFeedback?.canOpenRecording == true)
        #expect(bridge.noteRecordingLinkFeedback?.canRevealFile == true)
        #expect(bridge.noteRecordingLinkFeedback?.message.contains("Note is read-only") == true)

        bridge.clearNoteRecordingLinkFeedback()
        #expect(bridge.noteRecordingLinkFeedback == nil)
    }

    @Test("active note recording ownership and conflict are published")
    func activeNoteRecordingOwnershipAndConflictArePublished() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.setActiveNoteRecordingID("note-a")
        bridge.showNoteRecordingConflict(requestedNoteID: "note-b")

        #expect(bridge.activeNoteRecordingID == "note-a")
        #expect(bridge.noteRecordingConflict?.requestedNoteID == "note-b")
        #expect(bridge.noteRecordingConflict?.activeNoteID == "note-a")
        #expect(bridge.noteRecordingConflict?.message.contains("Another note owns") == true)

        bridge.setActiveNoteRecordingID(nil)
        #expect(bridge.activeNoteRecordingID == nil)
        #expect(bridge.noteRecordingConflict == nil)
    }
}
