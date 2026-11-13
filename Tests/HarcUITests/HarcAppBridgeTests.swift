import Testing
import Foundation
import HarcStore
@testable import HarcUI

@Suite("HarcAppBridge")
@MainActor
struct HarcAppBridgeTests {
    @Test("upload inspection dispatches only to the read-only publication callback")
    func uploadInspectionUsesExplicitMode() async {
        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        bridge.hostRuntimeReady = true
        bridge.hostReceiptInspectionUsesUploadID = true
        let id = UUID()
        bridge.hostReceiptInspectionInput = id.uuidString
        var receiptCalls = 0
        var publicationCalls = 0
        bridge.inspectHostReceiptBinding = { _ in receiptCalls += 1; return "unexpected" }
        bridge.inspectHostPublicationBinding = { received in
            #expect(received == id)
            publicationCalls += 1
            return "Publication verified; no authority granted"
        }
        await bridge.requestHostReceiptInspection()
        #expect(receiptCalls == 0)
        #expect(publicationCalls == 1)
        #expect(bridge.hostReceiptInspectionStatus == "Publication verified; no authority granted")
        bridge.hostReceiptInspectionUsesUploadID = false
        #expect(bridge.hostReceiptInspectionStatus == nil)
        #expect(bridge.hostReceiptInspectedID == nil)
    }

    @Test("receipt inspection routes exactly one UUID without invoking repair")
    func receiptInspectionRoutesOnlyReadOnlyCallback() async {
        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        bridge.hostRuntimeReady = true
        let id = UUID()
        bridge.hostReceiptInspectionInput = "  \(id.uuidString)\n"
        var requested: [UUID] = []
        var repairs = 0
        var migrations = 0
        bridge.onRepairHostReceipts = { repairs += 1 }
        bridge.onMigrateHostLibraryBindings = { migrations += 1 }
        bridge.inspectHostReceiptBinding = { [weak bridge] value in
            requested.append(value)
            #expect(bridge?.hostReceiptInspectionInProgress == true)
            // A repeated request while suspended must not issue another call.
            await bridge?.requestHostReceiptInspection()
            return "Read-only fixture result"
        }
        #expect(requested.isEmpty)
        await bridge.requestHostReceiptInspection()
        #expect(requested == [id])
        #expect(bridge.hostReceiptInspectedID == id)
        #expect(bridge.hostReceiptInspectionStatus == "Read-only fixture result")
        #expect(!bridge.hostReceiptInspectionInProgress)
        #expect(repairs == 0 && migrations == 0)
        bridge.hostReceiptInspectionInput = UUID().uuidString
        #expect(bridge.hostReceiptInspectionStatus == nil)
        #expect(bridge.hostReceiptInspectedID == nil)
    }

    @Test("invalid and unavailable receipt inspection never reaches the runtime",
          arguments: ["invalid", "offline", "repairing", "migrating"])
    func receiptInspectionRejectsUnavailableRequests(mode: String) async {
        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        bridge.hostRuntimeReady = mode != "offline"
        bridge.hostReceiptInspectionInput = mode == "invalid" ? "/private/not-a-recording-id" : UUID().uuidString
        bridge.hostReceiptRepairInProgress = mode == "repairing"
        bridge.hostLibraryMigrationInProgress = mode == "migrating"
        var calls = 0
        bridge.inspectHostReceiptBinding = { _ in calls += 1; return "unexpected" }
        await bridge.requestHostReceiptInspection()
        #expect(calls == 0)
        #expect(!bridge.hostReceiptInspectionInProgress)
        #expect(bridge.hostReceiptInspectedID == nil)
        #expect(bridge.hostReceiptInspectionStatus != nil)
    }

    @Test("receipt inspection errors are redacted and cancellation releases the action",
          arguments: [false, true])
    func receiptInspectionRedactsErrors(cancelled: Bool) async {
        let bridge = HarcAppBridge(recordingState: RecordingState(), trayState: PostStopTrayState())
        bridge.hostRuntimeReady = true
        bridge.hostReceiptInspectionInput = UUID().uuidString
        bridge.inspectHostReceiptBinding = { _ in
            if cancelled { throw CancellationError() }
            throw NSError(domain: "private", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "/private/audio.wav credential=secret"])
        }
        await bridge.requestHostReceiptInspection()
        #expect(!bridge.hostReceiptInspectionInProgress)
        #expect(bridge.hostReceiptInspectionStatus?.contains("credential") == false)
        #expect(bridge.hostReceiptInspectionStatus?.contains("/private") == false)
        #expect(bridge.hostReceiptInspectionStatus?.contains("No repair was requested") == true)
    }

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

    @Test("recording stop in flight publishes loading state")
    func recordingStopInFlightPublishesLoadingState() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        #expect(bridge.recordingStopInFlight == false)
        bridge.beginRecordingStop()
        #expect(bridge.recordingStopInFlight == true)
        bridge.endRecordingStop()
        #expect(bridge.recordingStopInFlight == false)
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

    @Test("Host readiness distinguishes configured role from running runtime")
    func hostRuntimeReadinessPublishesFailureAndRecovery() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.runtimeStartupError = "The Keychain returned unexpected status -34018."
        #expect(bridge.hostRuntimeReady == false)
        #expect(bridge.runtimeStartupError != nil)

        bridge.runtimeStartupError = nil
        bridge.hostRuntimeReady = true
        #expect(bridge.hostRuntimeReady == true)
        #expect(bridge.runtimeStartupError == nil)
    }

    @Test("Client readiness distinguishes configured role from running runtime")
    func clientRuntimeReadinessPublishesFailureAndRecovery() {
        let bridge = HarcAppBridge(
            recordingState: RecordingState(),
            trayState: PostStopTrayState()
        )

        bridge.runtimeStartupError = "The installation identity is unavailable."
        #expect(bridge.clientRuntimeReady == false)
        #expect(bridge.runtimeStartupError != nil)

        bridge.runtimeStartupError = nil
        bridge.clientRuntimeReady = true
        #expect(bridge.clientRuntimeReady == true)
        #expect(bridge.runtimeStartupError == nil)
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
