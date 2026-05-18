import Testing
import Foundation
import HarcStore
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

    @Test("recovery artifacts publish through bridge")
    func recoveryArtifactsPublishThroughBridge() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )
        let artifact = recoveryArtifact(status: .pending)

        bridge.setRecoveryArtifacts([artifact])

        #expect(bridge.recoveryArtifacts == [artifact])
        #expect(RecoveryInboxModel.unresolvedCount(in: bridge.recoveryArtifacts) == 1)
    }

    @Test("recovery inbox action availability follows artifact status")
    func recoveryInboxActionAvailability() {
        let rows = RecoveryInboxModel.rows(for: [
            recoveryArtifact(id: "pending", status: .pending),
            recoveryArtifact(id: "recovering", status: .recovering),
            recoveryArtifact(id: "recovered", status: .recovered),
            recoveryArtifact(id: "discarded", status: .discarded),
            recoveryArtifact(id: "failed", status: .failed),
        ])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        #expect(byID["pending"]?.canRecover == true)
        #expect(byID["pending"]?.canDiscard == true)
        #expect(byID["recovering"]?.canRecover == false)
        #expect(byID["recovering"]?.canReveal == false)
        #expect(byID["recovered"]?.canRecover == false)
        #expect(byID["recovered"]?.canReveal == true)
        #expect(byID["failed"]?.canRecover == true)
        #expect(byID["discarded"] == nil)
    }

    @Test("active capture status publishes source and transcript updates")
    func activeCaptureStatusPublishesTransitions() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )
        let startedAt = Date(timeIntervalSince1970: 1_779_000_000)
        let transcriptAt = startedAt.addingTimeInterval(8)

        bridge.setActiveCaptureStatus(ActiveCaptureStatus(
            sourceState: .micAndSystemAudio,
            cachePath: "/tmp/harc-cache",
            destinationPath: "/Users/me/Harc",
            startedAt: startedAt
        ))

        #expect(bridge.activeCaptureStatus?.sourceState == .micAndSystemAudio)
        #expect(bridge.activeCaptureStatus?.cachePath == "/tmp/harc-cache")
        #expect(bridge.activeCaptureStatus?.transcriptAgeText(referenceDate: transcriptAt) == "Transcript waiting")

        bridge.updateActiveCaptureSource(.micOnly)
        bridge.markActiveTranscriptUpdate(at: transcriptAt)

        #expect(bridge.activeCaptureStatus?.sourceState == .micOnly)
        #expect(bridge.activeCaptureStatus?.sourceState.warningText?.contains("System audio") == true)
        #expect(bridge.activeCaptureStatus?.transcriptAgeText(referenceDate: transcriptAt.addingTimeInterval(12)) == "Transcript updated 12s ago")

        bridge.setActiveCaptureStatus(nil)
        #expect(bridge.activeCaptureStatus == nil)
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

    private func recoveryArtifact(
        id: String = "artifact-1",
        status: RecoveryArtifact.Status
    ) -> RecoveryArtifact {
        RecoveryArtifact(
            id: id,
            kind: .interruptedWAV,
            status: status,
            sourceURL: URL(fileURLWithPath: "/tmp/\(id).wav"),
            destinationURL: URL(fileURLWithPath: "/tmp/Harc"),
            title: "Interrupted recording",
            detail: "cache WAV"
        )
    }
}
