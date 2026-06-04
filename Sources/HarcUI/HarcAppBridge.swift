import SwiftUI
import HarcStore

/// Glue between AppDelegate (which owns the recording lifecycle, daemon
/// launcher, store, etc.) and the SwiftUI `MenuBarExtra` scene. AppDelegate
/// publishes the small slice of state the menu-bar panel needs, and the
/// scene observes the bridge directly.
///
/// Keeping this as a single observable object — rather than re-injecting a
/// pile of `EnvironmentObject`s — is what lets the menu-bar surface stay
/// declarative without forcing AppDelegate to grow a SwiftUI hosting layer.
@MainActor
public final class HarcAppBridge: ObservableObject {
    public let recordingState: RecordingState
    public let trayState: PostStopTrayState
    /// Narrow observable for the always-visible menu-bar label. Re-renders
    /// only on isRecording/pasteFlash changes (effectively never during a
    /// recording). Without this split, the menu-bar label would re-render
    /// 10× per second from amplitudeHistory pulses — wasted work that was
    /// saturating the main thread mid-recording.
    public let iconState: MenuBarIconState

    @Published public var frontmostAppName: String? = nil
    @Published public var frontmostPasteDenied: Bool = false
    @Published public var amplitudeHistory: [Float] = []
    @Published public var autoStopPhase: AutoStopController.Phase = .idle
    @Published public var autoStopWarningSeconds: Int = AutoStopController.Config.defaults.warningSeconds
    @Published public var autoStopThresholdMinutes: Int = 5
    @Published public var autoStopMicDb: Float = -.infinity
    @Published public var autoStopSystemDb: Float = -.infinity
    @Published public var autoStopLastDurationText: String? = nil
    @Published public private(set) var stopRecovery: StopRecoveryInfo? = nil
    @Published public private(set) var activeCaptureStatus: ActiveCaptureStatus? = nil
    @Published public var destinationReady: Bool = true
    @Published public var destinationPath: String = ""
    @Published public var captureReadinessText: String = "Mic + system audio"
    @Published public var captureReadinessWarning: Bool = false
    @Published public var sttReadinessText: String = "Local STT"
    @Published public var summarizerReadinessText: String = "Summary unavailable"
    @Published public var summarizerReady: Bool = false
    @Published public var embedderReadinessText: String = "Search embedder unavailable"
    @Published public var embedderReady: Bool = false
    @Published public var speakerIDReadinessText: String = "Speaker ID ready"
    @Published public var speakerIDReady: Bool = true
    @Published public var notificationsReadinessText: String = "Notifications off"
    @Published public var notificationsReady: Bool = false
    @Published public var accessibilityReadinessText: String = "Paste permission unknown"
    @Published public var accessibilityReady: Bool = false
    @Published public private(set) var recoveryArtifacts: [RecoveryArtifact] = []
    /// Mirror for the panel + recording-pill consumers that DO want the
    /// flash. Kept on the bridge as well so existing bridge-observers
    /// (panel) react. Always set in lockstep with `iconState.pasteFlash`.
    @Published public private(set) var pasteFlash: PasteFlash? = nil
    @Published public private(set) var pasteStatusMessage: String? = nil
    @Published public private(set) var noteRecordingLinkFeedback: NoteRecordingLinkFeedback? = nil
    @Published public private(set) var activeNoteRecordingID: String? = nil
    @Published public private(set) var noteRecordingConflict: NoteRecordingConflict? = nil
    @Published public private(set) var recordingStopInFlight: Bool = false

    public var onStartStop: () -> Void = {}
    public var onStartRecordingForNote: (String) -> Void = { _ in }
    public var onOpenWindow: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteIntoFrontmost: () -> Void = {}
    public var onOpenLastRecording: () -> Void = {}
    public var onKeepRecording: () -> Void = {}
    public var onStopNow: () -> Void = {}
    public var onOpenSettings: () -> Void = {}
    public var onRevealStopRecovery: () -> Void = {}
    public var onRetryStopRecovery: () -> Void = {}
    public var onDismissStopRecovery: () -> Void = {}
    public var onAttachLatestRecordingToNote: (String) -> Void = { _ in }
    public var onOpenNoteLinkedRecording: (NoteRecordingLinkFeedback) -> Void = { _ in }
    public var onRevealNoteLinkedRecordingFile: (NoteRecordingLinkFeedback) -> Void = { _ in }
    public var onRecoverRecoveryArtifact: (String) -> Void = { _ in }
    public var onRevealRecoveryArtifact: (String) -> Void = { _ in }
    public var onDiscardRecoveryArtifact: (String) -> Void = { _ in }

    public init(recordingState: RecordingState, trayState: PostStopTrayState) {
        self.recordingState = recordingState
        self.trayState = trayState
        self.iconState = MenuBarIconState()
    }

    /// Flash the menu-bar icon for a brief moment to signal the auto-paste
    /// outcome. Replaces the legacy MenuBarFlash that was deleted with the
    /// popover. Auto-clears after `flashDuration`.
    public func flashPaste(_ outcome: PasteFlash) {
        reportPaste(outcome, message: nil)
    }

    public func reportPaste(_ outcome: PasteFlash, message: String?) {
        pasteStatusMessage = message
        pasteFlash = outcome
        iconState.pasteFlash = outcome
        let captureToken = UUID()
        currentFlashToken = captureToken
        Task { [weak self, captureToken] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            // Only clear if no newer flash superseded us.
            if self.currentFlashToken == captureToken {
                await MainActor.run {
                    self.pasteStatusMessage = nil
                    self.pasteFlash = nil
                    self.iconState.pasteFlash = nil
                }
            }
        }
    }

    public func showStopRecovery(_ info: StopRecoveryInfo) {
        stopRecovery = info
    }

    public func clearStopRecovery() {
        stopRecovery = nil
    }

    public func beginRecordingStop() {
        recordingStopInFlight = true
    }

    public func endRecordingStop() {
        recordingStopInFlight = false
    }

    public func setRecoveryArtifacts(_ artifacts: [RecoveryArtifact]) {
        recoveryArtifacts = artifacts
    }

    public func setActiveCaptureStatus(_ status: ActiveCaptureStatus?) {
        activeCaptureStatus = status
    }

    public func updateActiveCaptureSource(_ sourceState: ActiveCaptureStatus.SourceState) {
        activeCaptureStatus = activeCaptureStatus?.updatingSource(sourceState)
    }

    public func markActiveTranscriptUpdate(at date: Date = Date()) {
        activeCaptureStatus = activeCaptureStatus?.markingTranscriptUpdate(at: date)
    }

    public func showNoteRecordingLinked(
        noteID: String,
        recordingTitle: String,
        recordingID: Int64?,
        wavPath: String?
    ) {
        noteRecordingLinkFeedback = NoteRecordingLinkFeedback(
            noteID: noteID,
            status: .linked,
            recordingTitle: recordingTitle,
            recordingID: recordingID,
            wavPath: wavPath,
            message: "Linked \(recordingTitle) to this note."
        )
    }

    public func showNoteRecordingMissingSavedID(
        noteID: String,
        recordingTitle: String,
        wavPath: String?
    ) {
        noteRecordingLinkFeedback = NoteRecordingLinkFeedback(
            noteID: noteID,
            status: .recoveryNeeded,
            recordingTitle: recordingTitle,
            recordingID: nil,
            wavPath: wavPath,
            message: "Recording finished, but Harc could not find its Library ID to attach it automatically."
        )
    }

    public func showNoteRecordingLinkFailed(
        noteID: String,
        recordingTitle: String,
        recordingID: Int64?,
        wavPath: String?,
        errorDescription: String
    ) {
        noteRecordingLinkFeedback = NoteRecordingLinkFeedback(
            noteID: noteID,
            status: .recoveryNeeded,
            recordingTitle: recordingTitle,
            recordingID: recordingID,
            wavPath: wavPath,
            message: "Recording finished, but Harc could not attach it to the note: \(errorDescription)"
        )
    }

    public func clearNoteRecordingLinkFeedback() {
        noteRecordingLinkFeedback = nil
    }

    public func setActiveNoteRecordingID(_ noteID: String?) {
        activeNoteRecordingID = noteID
        if noteID == nil {
            noteRecordingConflict = nil
        }
    }

    public func showNoteRecordingConflict(requestedNoteID: String) {
        noteRecordingConflict = NoteRecordingConflict(
            requestedNoteID: requestedNoteID,
            activeNoteID: activeNoteRecordingID
        )
    }

    public func clearNoteRecordingConflict() {
        noteRecordingConflict = nil
    }

    private var currentFlashToken: UUID = UUID()
}

/// Narrow observable read by the always-visible menu-bar label. Holds only
/// the fields the label actually reads; high-frequency feeds like
/// amplitudeHistory live on `HarcAppBridge` instead so the label doesn't
/// re-render on every audio tick.
@MainActor
public final class MenuBarIconState: ObservableObject {
    @Published public var isRecording: Bool = false
    @Published public var pasteFlash: PasteFlash? = nil
    public init() {}
}

/// Outcome of a post-stop auto-paste run, used as a one-shot tint hint
/// on the menu-bar bars icon.
public enum PasteFlash: Sendable, Equatable {
    case success
    case skipped
    case failure
}

public struct NoteRecordingLinkFeedback: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case linked
        case recoveryNeeded
    }

    public var id: String { "\(noteID):\(recordingID.map(String.init) ?? wavPath ?? recordingTitle):\(status)" }
    public var noteID: String
    public var status: Status
    public var recordingTitle: String
    public var recordingID: Int64?
    public var wavPath: String?
    public var message: String

    public var isRecoveryNeeded: Bool { status == .recoveryNeeded }
    public var canOpenRecording: Bool { recordingID != nil || wavPath != nil }
    public var canRevealFile: Bool { wavPath != nil }
}

public struct NoteRecordingConflict: Identifiable, Sendable, Equatable {
    public var requestedNoteID: String
    public var activeNoteID: String?

    public var id: String {
        "\(requestedNoteID):\(activeNoteID ?? "general")"
    }

    public var message: String {
        if activeNoteID == nil {
            return "A general recording is already running. Open the active recording controls before starting capture into this note."
        }
        return "Another note owns the active recording. Open the active recording controls before starting capture into this note."
    }
}

public struct StopRecoveryInfo: Equatable, Sendable {
    public var title: String
    public var message: String
    public var cacheDirectoryPath: String
    public var isRecovering: Bool

    public init(
        title: String,
        message: String,
        cacheDirectoryPath: String,
        isRecovering: Bool = false
    ) {
        self.title = title
        self.message = message
        self.cacheDirectoryPath = cacheDirectoryPath
        self.isRecovering = isRecovering
    }
}
