import Foundation
import HarcDomain

/// This identity stays stable when a local recording reaches the Mac.
enum HarcMobileRecordingReference: Hashable {
    case origin(OriginRecordingID)
    case canonical(CanonicalRecordingID)

    func resolve(
        local: [HarcMobileLocalRecording],
        host: [LibraryRecordingSummary],
        fallbackLocal: HarcMobileLocalRecording? = nil
    ) -> HarcMobileResolvedRecording {
        switch self {
        case .origin(let origin):
            let localRecording = local.first { $0.originID == origin }
                ?? fallbackLocal.flatMap { $0.originID == origin ? $0 : nil }
            let matches = host.filter { $0.originID == origin }
            // Ambiguous mappings must not enrich the local recording.
            return .init(local: localRecording, host: matches.count == 1 ? matches[0] : nil)
        case .canonical(let canonical):
            let hostRecording = host.first { $0.canonicalID == canonical }
            let localRecording = hostRecording?.originID.flatMap { origin in
                local.first { $0.originID == origin }
                    ?? fallbackLocal.flatMap { $0.originID == origin ? $0 : nil }
            }
            return .init(local: localRecording, host: hostRecording)
        }
    }
}

struct HarcMobileResolvedRecording: Equatable {
    let local: HarcMobileLocalRecording?
    let host: LibraryRecordingSummary?
}

/// Audio safety, processing and actual summary availability are independent.
struct HarcMobileRecordingDetailPresentation: Equatable {
    let localAudioMessage: String?
    let macAudioMessage: String
    let processingTitle: String
    let processingMessage: String
    let summaryPlaceholder: String?
    let warning: String?

    var processingSymbol: String {
        if processingTitle == "Connection needs attention" { return "lock.trianglebadge.exclamationmark" }
        if processingTitle.hasPrefix("Last known:") { return "clock" }
        if processingTitle.contains("needs") { return "exclamationmark.triangle" }
        if processingTitle == "Processing complete" { return "checkmark.circle" }
        return "desktopcomputer"
    }

    static func make(
        recording: HarcMobileResolvedRecording,
        hostHealth: HarcMobileHostHealthStatus,
        libraryIsOffline: Bool,
        summary: String?,
        partialRecording: Bool = false
    ) -> Self {
        let local = recording.local
        let host = recording.host
        let securityBlocked = local?.transferState == .securityBlocked
            || isPairingRepairRequired(hostHealth)
        let macMessage: String
        if local?.transferState == .committed {
            macMessage = "Mac receipt verified"
        } else if host?.canonicalAudio.availability == .available {
            macMessage = libraryIsOffline
                ? "Listed on your Mac at last sync" : "Listed on your Mac"
        } else if securityBlocked {
            macMessage = "Sending blocked: pairing needs attention"
        } else {
            switch local?.transferState {
            case .transferring: macMessage = "Sending to your Mac"
            case .retryNeeded: macMessage = "Waiting to retry sending to your Mac"
            default: macMessage = "Not yet verified on your Mac"
            }
        }

        let title: String
        let message: String
        if securityBlocked {
            title = "Connection needs attention"
            message = "Review your Mac pairing in Setup & Sync before sending or updating this recording."
        } else if let host {
            let status: (String, String) = switch host.processing.state {
            case .pending:
                ("Waiting for processing", "Your Mac has not reported a transcript yet.")
            case .transcribing:
                ("Transcribing on your Mac", "Your Mac is preparing the transcript.")
            case .projecting:
                ("Preparing recording details", "Your Mac is preparing derived recording details.")
            case .ready:
                ("Processing complete", "Available results from your Mac appear below.")
            case .degraded:
                ("Some processing needs attention", "Some results may be incomplete. Review this recording on your Mac.")
            case .failedRecoverable:
                ("Processing needs another attempt", "Your Mac reported a processing failure. Audio safety is shown separately above.")
            }
            if libraryIsOffline {
                title = "Last known: " + status.0
                message = "Showing saved status. Reconnect to your Mac to check for updated results."
            } else {
                title = status.0
                message = status.1
            }
        } else {
            title = "Summary and transcript need your Mac"
            switch hostHealth {
            case .unpaired:
                message = "Pair with your Mac in Setup & Sync to send this recording for processing."
            case .unavailable:
                message = "Reconnect to your Mac to send this recording and receive its transcript and summary when available."
            default:
                message = "After this recording reaches your Mac, available transcripts and summaries can appear here."
            }
        }
        let hasSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return Self(
            localAudioMessage: local == nil ? nil : "Saved on this iPhone",
            macAudioMessage: macMessage,
            processingTitle: title,
            processingMessage: message,
            summaryPlaceholder: hasSummary ? nil : "No summary is available yet. Summaries require your Mac; processing status does not mean a summary has been generated.",
            warning: partialRecording
                ? "Recording stopped because storage ran out. Only the audio captured before storage was exhausted was saved."
                : nil
        )
    }

    private static func isPairingRepairRequired(_ health: HarcMobileHostHealthStatus) -> Bool {
        if case .pairingRepairRequired = health { return true }
        return false
    }
}

enum HarcMobilePostRecordingDecision {
    /// Both finalization outcomes open the recording; partial saves retain their warning.
    static func autoOpenSavedRecording(
        state: HarcMobileCaptureCoordinator.State,
        isRecordTab: Bool
    ) -> UUID? {
        guard isRecordTab else { return nil }
        switch state {
        case .saved(let id), .storageExhausted(let id): return id
        default: return nil
        }
    }

    static func canStartNewRecording(state: HarcMobileCaptureCoordinator.State) -> Bool {
        switch state {
        case .idle, .saved, .storageExhausted, .failed: true
        case .requestingPermission, .starting, .recording, .stopping: false
        }
    }
}

/// Each editor owns the exact revision against which its text was drafted.
/// Refreshing other recording details must not silently rebase an unsaved edit.
struct HarcMobileRecordingTextDraft: Equatable {
    var text: String
    private(set) var baselineText: String
    private(set) var baselineSummary: LibraryRecordingSummary?
    private var queuedText: String?
    private var queuedServerText: String?
    private(set) var queuedOperationID: OperationID?

    init(text: String = "") {
        self.text = text
        self.baselineText = text
        self.baselineSummary = nil
        self.queuedText = nil
        self.queuedServerText = nil
        self.queuedOperationID = nil
    }

    var isDirty: Bool { text != baselineText }
    var hasQueuedSubmission: Bool { queuedText != nil }
    var hasUnsavedChanges: Bool { text != (queuedText ?? baselineText) }

    /// The outbox has durably saved this exact submission, not necessarily the
    /// newest text if the user continued typing while persistence was in flight.
    mutating func markQueued(
        submitted: String,
        expectedServerText: String? = nil,
        operationID: OperationID? = nil
    ) {
        queuedText = submitted
        queuedServerText = expectedServerText ?? submitted
        queuedOperationID = operationID
    }

    /// Call after receiving Host text. Matching text can first confirm the saved
    /// baseline; an operation that settled before a later remote edit must only
    /// release the pending marker, never silently rebase the editor to that edit.
    mutating func reconcilePendingOperations(_ pending: Set<OperationID>) {
        guard let queuedOperationID, !pending.contains(queuedOperationID) else { return }
        queuedText = nil
        queuedServerText = nil
        self.queuedOperationID = nil
    }

    mutating func receive(text: String, summary: LibraryRecordingSummary,
                          pendingOperations: Set<OperationID>? = nil) {
        if let queuedOperationID {
            // Another client may independently write the same field value.
            // Only authoritative operation settlement permits acknowledgement.
            guard pendingOperations?.contains(queuedOperationID) == false else { return }
        }
        if let queuedText {
            guard text == queuedServerText else { return }
            // Normalize only the submitted editor value, never newer typing.
            if self.text == queuedText { self.text = text }
            baselineText = text
            baselineSummary = summary
            self.queuedText = nil
            queuedServerText = nil
            queuedOperationID = nil
            return
        }
        guard baselineSummary == nil || !isDirty else { return }
        self.text = text
        baselineText = text
        baselineSummary = summary
    }

    /// A post-save fetch may already contain another client's later edit. Only
    /// adopt the baseline when its value matches the expected normalized submission.
    /// Preserve newer typing. The return value indicates editor replacement.
    @discardableResult
    mutating func acceptSaved(
        submitted: String,
        summary: LibraryRecordingSummary,
        serverText: String,
        expectedServerText: String? = nil
    ) -> Bool {
        guard serverText == (expectedServerText ?? submitted) else { return false }
        let replacesEditorText = text == submitted
        if queuedText == submitted {
            queuedText = nil
            queuedServerText = nil
            queuedOperationID = nil
        }
        if replacesEditorText { text = serverText }
        baselineText = serverText
        baselineSummary = summary
        return replacesEditorText
    }

    /// The user explicitly chose the Mac's value, authorizing a rebase and
    /// discarding the previously queued conflict. Typing after that choice stays.
    @discardableResult
    mutating func acceptHostValue(
        submittedEditorText: String,
        summary: LibraryRecordingSummary,
        serverText: String
    ) -> Bool {
        let replacesEditorText = text == submittedEditorText
        queuedText = nil
        queuedServerText = nil
        queuedOperationID = nil
        if replacesEditorText { text = serverText }
        baselineText = serverText
        baselineSummary = summary
        return replacesEditorText
    }
}
