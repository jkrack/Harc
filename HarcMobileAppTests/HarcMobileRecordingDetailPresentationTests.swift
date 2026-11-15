import Foundation
import HarcDomain
import XCTest
@testable import HarcMobile

final class HarcMobileRecordingDetailPresentationTests: XCTestCase {
    func testPromotionRetainsOriginAndLocalPlayback() throws {
        let local = try localRecording()
        let reference = HarcMobileRecordingReference.origin(local.originID)
        XCTAssertNil(reference.resolve(local: [local], host: []).host)
        let host = try hostRecording(origin: local.originID)
        let resolved = reference.resolve(local: [local], host: [host])
        XCTAssertEqual(resolved.local, local)
        XCTAssertEqual(resolved.host, host)
        XCTAssertEqual(reference, .origin(local.originID))
    }

    func testUUIDCollisionAcrossDevicesNeverEnrichesOrUsesFallback() throws {
        let local = try localRecording()
        let foreign = try localRecording(deviceByte: 2)
        XCTAssertEqual(local.id, foreign.id)
        let host = try hostRecording(origin: foreign.originID)
        let reference = HarcMobileRecordingReference.origin(local.originID)
        XCTAssertNil(reference.resolve(local: [local], host: [host]).host)
        XCTAssertNil(reference.resolve(local: [], host: [], fallbackLocal: foreign).local)
        XCTAssertNil(HarcMobileRecordingReference.canonical(host.canonicalID)
            .resolve(local: [local], host: [host], fallbackLocal: local).local)
    }

    func testMatchingFallbackSurvivesInventoryRefresh() throws {
        let local = try localRecording()
        XCTAssertEqual(HarcMobileRecordingReference.origin(local.originID)
            .resolve(local: [], host: [], fallbackLocal: local).local, local)
    }

    func testCanonicalWithoutOriginDoesNotGuessLocalAudio() throws {
        let local = try localRecording()
        let host = try hostRecording(origin: nil)
        XCTAssertNil(HarcMobileRecordingReference.canonical(host.canonicalID)
            .resolve(local: [local], host: [host], fallbackLocal: local).local)
    }

    func testReadyDoesNotMeanSummaryExists() throws {
        for summary in [nil, "", "  \n"] as [String?] {
            let presentation = try presentation(state: .ready, summary: summary)
            XCTAssertNotNil(presentation.summaryPlaceholder)
            XCTAssertFalse(presentation.processingTitle.localizedCaseInsensitiveContains("summary"))
        }
        XCTAssertNil(try presentation(state: .ready, summary: "Actual summary").summaryPlaceholder)
    }

    func testCachedProcessingNeverClaimsLiveProgress() throws {
        for state in RecordingProcessingState.allCases {
            let result = try presentation(state: state, offline: true)
            XCTAssertTrue(result.processingTitle.hasPrefix("Last known:"))
            XCTAssertTrue(result.processingMessage.contains("Showing saved status"))
            XCTAssertNotNil(result.summaryPlaceholder)
        }
    }

    func testFailuresDoNotEraseIndependentAudioSafety() throws {
        for state in [RecordingProcessingState.degraded, .failedRecoverable] {
            let result = try presentation(state: state, transfer: .committed)
            XCTAssertEqual(result.localAudioMessage, "Saved on this iPhone")
            XCTAssertEqual(result.macAudioMessage, "Mac receipt verified")
            XCTAssertTrue(result.processingTitle.contains("needs"))
            XCTAssertNotNil(result.summaryPlaceholder)
        }
    }

    func testPendingAndProjectingNeverClaimSummaryGeneration() throws {
        for state in [RecordingProcessingState.pending, .transcribing, .projecting] {
            let result = try presentation(state: state)
            XCTAssertFalse(result.processingMessage.contains("summary"))
            XCTAssertNotNil(result.summaryPlaceholder)
        }
    }

    func testLocalOnlyPairingOfflineAndSecurityStates() throws {
        let local = try localRecording()
        let unpaired = HarcMobileRecordingDetailPresentation.make(
            recording: .init(local: local, host: nil), hostHealth: .unpaired,
            libraryIsOffline: true, summary: nil)
        XCTAssertTrue(unpaired.processingMessage.contains("Pair with your Mac"))
        XCTAssertEqual(unpaired.localAudioMessage, "Saved on this iPhone")
        let offline = HarcMobileRecordingDetailPresentation.make(
            recording: .init(local: local, host: nil),
            hostHealth: .unavailable(lastAttemptedAt: .distantPast),
            libraryIsOffline: true, summary: nil)
        XCTAssertTrue(offline.processingMessage.contains("Reconnect"))
        let blocked = HarcMobileRecordingDetailPresentation.make(
            recording: .init(local: try localRecording(transfer: .securityBlocked), host: nil),
            hostHealth: .unpaired, libraryIsOffline: true, summary: nil)
        XCTAssertEqual(blocked.processingTitle, "Connection needs attention")
        XCTAssertTrue(blocked.macAudioMessage.contains("blocked"))
    }

    @MainActor
    func testAutoOpenOnlySavedInRecordTabAndNewRecordingWaitsForStop() {
        let id = UUID()
        XCTAssertEqual(HarcMobilePostRecordingDecision.autoOpenSavedRecording(
            state: .saved(recordingUUID: id), isRecordTab: true), id)
        XCTAssertNil(HarcMobilePostRecordingDecision.autoOpenSavedRecording(
            state: .saved(recordingUUID: id), isRecordTab: false))
        for state in [HarcMobileCaptureCoordinator.State.stopping,
                      .recording(startedAt: .distantPast), .starting, .requestingPermission] {
            XCTAssertFalse(HarcMobilePostRecordingDecision.canStartNewRecording(state: state))
            XCTAssertNil(HarcMobilePostRecordingDecision.autoOpenSavedRecording(state: state, isRecordTab: true))
        }
        XCTAssertEqual(HarcMobilePostRecordingDecision.autoOpenSavedRecording(
            state: .storageExhausted(recordingUUID: id), isRecordTab: true), id)
        XCTAssertTrue(HarcMobilePostRecordingDecision.canStartNewRecording(state: .saved(recordingUUID: id)))
    }

    func testPartialRecordingCarriesStorageWarning() throws {
        let result = HarcMobileRecordingDetailPresentation.make(
            recording: .init(local: try localRecording(), host: nil),
            hostHealth: .unpaired, libraryIsOffline: true, summary: nil, partialRecording: true)
        XCTAssertTrue(result.warning?.contains("Only the audio captured") == true)
    }

    func testDirtyDraftRefreshPreservesTextAndOriginalRevision() throws {
        let original = try hostRecording(origin: nil)
        let refreshed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "My unsaved edit"
        draft.receive(text: "Changed on Mac", summary: refreshed)
        XCTAssertEqual(draft.text, "My unsaved edit")
        XCTAssertEqual(draft.baselineText, "Original")
        XCTAssertEqual(draft.baselineSummary, original)
        XCTAssertTrue(draft.isDirty)
    }

    func testCleanDraftRefreshAdoptsTextAndRevision() throws {
        let original = try hostRecording(origin: nil)
        let refreshed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.receive(text: "Changed on Mac", summary: refreshed)
        XCTAssertEqual(draft.text, "Changed on Mac")
        XCTAssertEqual(draft.baselineText, "Changed on Mac")
        XCTAssertEqual(draft.baselineSummary, refreshed)
        XCTAssertFalse(draft.isDirty)
    }

    func testSuccessfulSaveAcceptsServerNormalizationWhenTextUnchanged() throws {
        let original = try hostRecording(origin: nil)
        let saved = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "  Submitted  "
        XCTAssertTrue(draft.acceptSaved(submitted: "  Submitted  ", summary: saved, serverText: "Submitted", expectedServerText: "Submitted"))
        XCTAssertEqual(draft.text, "Submitted")
        XCTAssertEqual(draft.baselineText, "Submitted")
        XCTAssertEqual(draft.baselineSummary, saved)
        XCTAssertFalse(draft.isDirty)
    }

    func testSuccessfulSavePreservesNewTypingAndAdvancesConfirmedBaseline() throws {
        let original = try hostRecording(origin: nil)
        let saved = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Submitted"
        let submitted = draft.text
        draft.text = "Typed while saving"
        XCTAssertFalse(draft.acceptSaved(submitted: submitted, summary: saved, serverText: "Submitted"))
        draft.receive(text: "Submitted", summary: saved)
        XCTAssertEqual(draft.text, "Typed while saving")
        XCTAssertEqual(draft.baselineText, "Submitted")
        XCTAssertEqual(draft.baselineSummary, saved)
        XCTAssertTrue(draft.isDirty)
    }

    func testQueuedDraftHasNoUnsavedChangesAndConfirmationAdvancesBaseline() throws {
        let original = try hostRecording(origin: nil)
        let confirmed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued"
        draft.markQueued(submitted: "Queued")
        XCTAssertTrue(draft.hasQueuedSubmission)
        XCTAssertTrue(draft.isDirty)
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertEqual(draft.baselineSummary, original)
        draft.receive(text: "Queued", summary: confirmed)
        XCTAssertEqual(draft.text, "Queued")
        XCTAssertEqual(draft.baselineText, "Queued")
        XCTAssertEqual(draft.baselineSummary, confirmed)
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testQueuedConfirmationPreservesFurtherTypingAgainstConfirmedRevision() throws {
        let original = try hostRecording(origin: nil)
        let confirmed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued"
        draft.markQueued(submitted: "Queued")
        XCTAssertTrue(draft.hasQueuedSubmission)
        draft.text = "Further typing"
        XCTAssertTrue(draft.hasUnsavedChanges)
        draft.receive(text: "Queued", summary: confirmed)
        XCTAssertEqual(draft.text, "Further typing")
        XCTAssertEqual(draft.baselineText, "Queued")
        XCTAssertEqual(draft.baselineSummary, confirmed)
        XCTAssertTrue(draft.hasUnsavedChanges)
        draft.text = "Queued"
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testQueuedDraftDoesNotAcceptDifferentRemoteValue() throws {
        let original = try hostRecording(origin: nil)
        let unrelated = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued"
        draft.markQueued(submitted: "Queued")
        XCTAssertTrue(draft.hasQueuedSubmission)
        draft.receive(text: "Mac edit", summary: unrelated)
        XCTAssertEqual(draft.text, "Queued")
        XCTAssertEqual(draft.baselineSummary, original)
        XCTAssertEqual(draft.baselineText, "Original")
        XCTAssertFalse(draft.hasUnsavedChanges)
        // Reverting locally is another edit relative to the persisted queue.
        draft.text = "Original"
        draft.receive(text: "Mac edit", summary: unrelated)
        XCTAssertEqual(draft.text, "Original")
        XCTAssertEqual(draft.baselineSummary, original)
        XCTAssertTrue(draft.hasUnsavedChanges)
    }

    func testQueuedCanonicalTagsReconcileWithoutDiscardWarning() throws {
        let original = try hostRecording(origin: nil)
        let confirmed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = " zeta, alpha, zeta,  "
        draft.markQueued(submitted: draft.text, expectedServerText: "alpha, zeta")
        XCTAssertFalse(draft.hasUnsavedChanges)
        draft.receive(text: "alpha, zeta", summary: confirmed)
        XCTAssertEqual(draft.text, "alpha, zeta")
        XCTAssertEqual(draft.baselineSummary, confirmed)
        XCTAssertFalse(draft.isDirty)
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testQueuedWhitespaceClearingReconcilesNilServerRepresentation() throws {
        let original = try hostRecording(origin: nil)
        let confirmed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "  \n"
        draft.markQueued(submitted: draft.text, expectedServerText: "")
        XCTAssertFalse(draft.hasUnsavedChanges)
        draft.receive(text: "", summary: confirmed)
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.baselineText, "")
        XCTAssertEqual(draft.baselineSummary, confirmed)
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testNormalizedQueueConfirmationKeepsNewerTypingAndRejectsUnrelatedText() throws {
        let original = try hostRecording(origin: nil)
        let confirmed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "zeta,alpha"
        draft.markQueued(submitted: draft.text, expectedServerText: "alpha, zeta")
        draft.text = "zeta,alpha,beta"
        draft.receive(text: "Something else", summary: confirmed)
        XCTAssertEqual(draft.baselineSummary, original)
        draft.receive(text: "alpha, zeta", summary: confirmed)
        XCTAssertEqual(draft.text, "zeta,alpha,beta")
        XCTAssertEqual(draft.baselineText, "alpha, zeta")
        XCTAssertEqual(draft.baselineSummary, confirmed)
        XCTAssertTrue(draft.hasUnsavedChanges)
    }

    func testExplicitHostAcceptanceClearsOlderQueuedConflict() throws {
        let original = try hostRecording(origin: nil)
        let accepted = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued A"
        draft.markQueued(submitted: draft.text)
        draft.text = "Typed B"
        XCTAssertTrue(draft.acceptHostValue(submittedEditorText: "Typed B", summary: accepted,
                                            serverText: "Mac C"))
        XCTAssertEqual(draft.text, "Mac C")
        XCTAssertEqual(draft.baselineText, "Mac C")
        XCTAssertEqual(draft.baselineSummary, accepted)
        XCTAssertFalse(draft.hasUnsavedChanges)
        let newer = try revisedSummary(accepted)
        draft.receive(text: "Mac D", summary: newer)
        XCTAssertEqual(draft.text, "Mac D")
        XCTAssertEqual(draft.baselineSummary, newer)
    }

    func testExplicitHostAcceptancePreservesTypingAfterTapAndClearsQueue() throws {
        let original = try hostRecording(origin: nil)
        let accepted = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued A"
        draft.markQueued(submitted: draft.text)
        draft.text = "Typed B"
        let textAtTap = draft.text
        draft.text = "Typed after tap"
        XCTAssertFalse(draft.acceptHostValue(submittedEditorText: textAtTap, summary: accepted,
                                             serverText: "Mac C"))
        XCTAssertEqual(draft.text, "Typed after tap")
        XCTAssertEqual(draft.baselineText, "Mac C")
        XCTAssertEqual(draft.baselineSummary, accepted)
        XCTAssertTrue(draft.hasUnsavedChanges)
        draft.text = "Queued A"
        XCTAssertTrue(draft.hasUnsavedChanges, "The discarded queue must no longer count as persisted text")
        draft.text = "Mac C"
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    func testAppliedSaveFetchOfLaterRemoteEditDoesNotRebaseOrClearQueue() throws {
        let original = try hostRecording(origin: nil)
        let laterRemote = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "zeta,alpha"
        draft.markQueued(submitted: draft.text, expectedServerText: "alpha, zeta")
        let beforeFetch = draft
        XCTAssertFalse(draft.acceptSaved(submitted: "zeta,alpha", summary: laterRemote,
                                         serverText: "Another client edit", expectedServerText: "alpha, zeta"))
        XCTAssertEqual(draft, beforeFetch)
        draft.text = "New typing during fetch"
        let beforeSecondFetch = draft
        XCTAssertFalse(draft.acceptSaved(submitted: "zeta,alpha", summary: laterRemote,
                                         serverText: "Another client edit", expectedServerText: "alpha, zeta"))
        XCTAssertEqual(draft, beforeSecondFetch)
    }

    func testAppliedSaveDefaultExpectedValueRejectsUnrelatedRemoteText() throws {
        let original = try hostRecording(origin: nil)
        let laterRemote = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Submitted"
        let beforeFetch = draft
        XCTAssertFalse(draft.acceptSaved(submitted: "Submitted", summary: laterRemote, serverText: "Later edit"))
        XCTAssertEqual(draft, beforeFetch)
    }

    func testQueuedSpeakerRemovalReconcilesMissingLabelAndFutureReplacement() throws {
        let original = try hostRecording(origin: nil)
        let removed = try revisedSummary(original)
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Old name", summary: original)
        draft.markQueued(submitted: draft.text, expectedServerText: "")
        XCTAssertTrue(draft.hasQueuedSubmission)
        draft.receive(text: "", summary: removed)
        XCTAssertFalse(draft.hasQueuedSubmission)
        XCTAssertFalse(draft.hasUnsavedChanges)
        let replaced = try revisedSummary(removed)
        draft.receive(text: "Replacement", summary: replaced)
        XCTAssertEqual(draft.text, "Replacement")
        XCTAssertEqual(draft.baselineSummary, replaced)
    }

    func testSettledQueuedOperationReleasesSaveWithoutAdoptingLaterRemoteEdit() throws {
        let original = try hostRecording(origin: nil)
        let remote = try revisedSummary(original)
        let operation = OperationID(UUID())
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued A"
        draft.markQueued(submitted: draft.text, operationID: operation)
        draft.text = "Further typing"
        draft.receive(text: "Later remote D", summary: remote)
        draft.reconcilePendingOperations([])
        XCTAssertNil(draft.queuedOperationID)
        XCTAssertFalse(draft.hasQueuedSubmission)
        XCTAssertEqual(draft.text, "Further typing")
        XCTAssertEqual(draft.baselineText, "Original")
        XCTAssertEqual(draft.baselineSummary, original)
        XCTAssertTrue(draft.hasUnsavedChanges)
        draft.receive(text: "Later remote D", summary: remote)
        XCTAssertEqual(draft.baselineSummary, original)
        XCTAssertEqual(draft.text, "Further typing")
    }

    func testPendingOperationIdentityRetainsQueueUntilExactOperationSettles() throws {
        let original = try hostRecording(origin: nil)
        let remote = try revisedSummary(original)
        let operation = OperationID(UUID())
        let unrelated = OperationID(UUID())
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued A"
        draft.markQueued(submitted: draft.text, operationID: operation)
        let queued = draft
        draft.receive(text: "Remote D", summary: remote)
        draft.reconcilePendingOperations([operation, unrelated])
        XCTAssertEqual(draft, queued)
        XCTAssertEqual(draft.queuedOperationID, operation)
        XCTAssertTrue(draft.hasQueuedSubmission)
        XCTAssertFalse(draft.hasUnsavedChanges)
        draft.reconcilePendingOperations([unrelated])
        XCTAssertFalse(draft.hasQueuedSubmission)
        XCTAssertNil(draft.queuedOperationID)
        XCTAssertEqual(draft.baselineSummary, original)
        XCTAssertTrue(draft.hasUnsavedChanges)
    }

    func testMatchingRemoteTextCannotAcknowledgeStillPendingOperation() throws {
        let original = try hostRecording(origin: nil)
        let remote = try revisedSummary(original)
        let operation = OperationID(UUID())
        var draft = HarcMobileRecordingTextDraft()
        draft.receive(text: "Original", summary: original)
        draft.text = "Queued"
        draft.markQueued(submitted: "Queued", operationID: operation)
        draft.receive(text: "Queued", summary: remote, pendingOperations: [operation])
        XCTAssertTrue(draft.hasQueuedSubmission)
        XCTAssertEqual(draft.baselineSummary, original)
        draft.receive(text: "Queued", summary: remote, pendingOperations: nil)
        XCTAssertTrue(draft.hasQueuedSubmission, "A cache read failure cannot acknowledge an operation")
        draft.receive(text: "Queued", summary: remote, pendingOperations: [])
        XCTAssertFalse(draft.hasQueuedSubmission)
        XCTAssertEqual(draft.baselineSummary, remote)
        XCTAssertFalse(draft.hasUnsavedChanges)
    }

    private func revisedSummary(_ original: LibraryRecordingSummary) throws -> LibraryRecordingSummary {
        try .init(canonicalID: original.canonicalID, originID: original.originID,
                  revision: original.revision.next(), startedAt: original.startedAt,
                  processing: original.processing)
    }

    private func presentation(
        state: RecordingProcessingState,
        offline: Bool = false,
        summary: String? = nil,
        transfer: HarcMobileLocalRecording.TransferState = .localOnly
    ) throws -> HarcMobileRecordingDetailPresentation {
        let local = try localRecording(transfer: transfer)
        return .make(recording: .init(local: local, host: try hostRecording(origin: local.originID, state: state)),
                     hostHealth: .connected(lastVerifiedAt: .distantPast),
                     libraryIsOffline: offline, summary: summary)
    }

    private func localRecording(
        deviceByte: UInt8 = 1,
        transfer: HarcMobileLocalRecording.TransferState = .localOnly
    ) throws -> HarcMobileLocalRecording {
        let origin = OriginRecordingID(deviceID: try DeviceID(Data(repeating: deviceByte, count: 32)),
            recordingUUID: UUID(uuidString: "11111111-2222-4333-8444-000000000001")!)
        return .init(id: origin.recordingUUID, originID: origin, startedAt: .distantPast,
                     duration: 60, masterFileURL: URL(fileURLWithPath: "/tmp/detail-test.caf"),
                     transferState: transfer, discontinuities: [])
    }

    private func hostRecording(
        origin: OriginRecordingID?, state: RecordingProcessingState = .ready
    ) throws -> LibraryRecordingSummary {
        try .init(canonicalID: CanonicalRecordingID(UUID()), originID: origin, revision: .initial,
                  startedAt: .distantPast, processing: ProcessingDescriptor(state: state))
    }
}
