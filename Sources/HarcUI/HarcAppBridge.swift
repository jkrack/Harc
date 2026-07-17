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
    /// Honest speech-model readiness from the AppDelegate poller
    /// (`STTReadiness`). Optimistic default so the panel doesn't flash
    /// "blocked" in the second before the first poll answers.
    @Published public var sttReady: Bool = true
    @Published public var summarizerReadinessText: String = "Summary unavailable"
    @Published public var summarizerReady: Bool = false
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
    @Published public private(set) var recordingStopInFlight: Bool = false

    public var onStartStop: () -> Void = {}
    public var onStartDictation: () -> Void = {}
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
    public var onRecoverRecoveryArtifact: (String) -> Void = { _ in }
    public var onRevealRecoveryArtifact: (String) -> Void = { _ in }
    public var onDiscardRecoveryArtifact: (String) -> Void = { _ in }
    /// Run a dictation mode's transform on sample text (settings "Test"
    /// button). nil when the LLM stack isn't wired (previews/tests).
    public var testDictationTransform: ((DictationMode, String) async throws -> String)?

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
