import SwiftUI
import HarcAudio
import HarcCore
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
    /// Mic-only amplitude. The combined history can move from system audio
    /// while the selected microphone is dead, so capture safety must not use it.
    @Published public var microphoneAmplitudeHistory: [Float] = []
    @Published public var autoStopPhase: AutoStopController.Phase = .idle
    @Published public var autoStopWarningSeconds: Int = AutoStopController.Config.defaults.warningSeconds
    @Published public var autoStopThresholdMinutes: Int = 5
    @Published public var autoStopMicDb: Float = -.infinity
    @Published public var autoStopSystemDb: Float = -.infinity
    @Published public var autoStopLastDurationText: String? = nil
    @Published public private(set) var stopRecovery: StopRecoveryInfo? = nil
    @Published public private(set) var activeCaptureStatus: ActiveCaptureStatus? = nil
    /// State of the idle pre-roll ring; nil when the feature is off.
    ///
    /// Carries the failure reason, not just the banked count. Publishing only
    /// a number meant a ring whose mic tap never started — or died — rendered
    /// as "Ready to capture the last 0s", which is the app claiming to be
    /// armed while it is doing nothing at all.
    @Published public var preRollStatus: PreRollStatus? = nil
    @Published public var destinationReady: Bool = true
    @Published public var destinationPath: String = ""
    @Published public var captureReadinessText: String = "Mic + system audio"
    @Published public var captureReadinessWarning: Bool = false
    @Published public var availableMicrophones: [AudioInputDevice] = []
    @Published public var microphoneSelection: MicrophoneSelection = .systemDefault
    @Published public var selectedMicrophoneName: String = "System Default"
    @Published public var selectedMicrophoneAvailable: Bool = false
    @Published public var systemDefaultMicrophoneName: String? = nil
    /// Frozen when capture begins so a later system-default change cannot make
    /// the UI name a device different from the one the live engine opened.
    @Published public var activeMicrophoneName: String? = nil
    @Published public var sttReadinessText: String = "Local STT"
    /// Honest speech-model readiness from the AppDelegate poller
    /// (`STTReadiness`). Optimistic default so the panel doesn't flash
    /// "blocked" in the second before the first poll answers.
    @Published public var sttReady: Bool = true
    /// Speech-model download progress in [0, 1] while the daemon reports an
    /// active download; nil otherwise. Drives determinate progress bars.
    @Published public var sttDownloadProgress: Double? = nil
    @Published public var summarizerReadinessText: String = "Summary unavailable"
    @Published public var summarizerReady: Bool = false
    /// The active summarizer is on disk. Separate from `summarizerReady`,
    /// which also requires auto-summary to be on.
    @Published public var summarizerInstalled: Bool = false
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
    /// Title chosen in Quick Capture, live for the duration of the capture —
    /// the island and the sidebar record card both show it. Nil when the
    /// recording started nameless (⌃⌥R path).
    @Published public var activeCaptureTitle: String? = nil
    /// Open discard-undo window, shown on the island: the recording was
    /// stopped via Discard and will be deleted when `secondsRemaining` runs
    /// out unless the user hits Undo. Nil when no discard is pending.
    @Published public var discardCountdown: DiscardCountdown? = nil
    /// Newer release Sparkle has found (published by the app target's
    /// updater delegate) so the panel and About can show an update row.
    @Published public var availableUpdate: AvailableUpdate? = nil
    /// The configured role is only a preference; this reports whether the
    /// resident Host graph actually completed startup.
    @Published public var hostRuntimeReady: Bool = false
    /// Mirrors completion of the desktop Client graph and the preserved
    /// On This Mac library bootstrap. Settings uses this instead of treating a
    /// configured Client preference as proof that pairing/storage are usable.
    @Published public var clientRuntimeReady: Bool = false
    /// Present only in Client mode. Holds the latest explicit archive
    /// reconciliation result so Settings and Activity report the same facts.
    @Published public var clientRecoverSyncState: ClientRecoverSyncState? = nil
    /// Live transfer status from the Client outbox coordinator.
    @Published public var clientTransferStatusText: String? = nil
    /// Privacy-bounded, persistent Client transport events. The Activity
    /// surface renders these without reading private application files itself.
    @Published public var clientDiagnosticLogEntries: [HarcDiagnosticLogEntry] = []
    /// Persists a launch failure after stderr disappears so Settings cannot
    /// claim "Host" while every Host-only action is absent.
    @Published public var runtimeStartupError: String? = nil
    /// True only when this build or launch environment names a Harc Remote
    /// service origin. The preference remains visible but cannot be enabled
    /// accidentally in an unconfigured build.
    @Published public var remoteRelayAvailable: Bool = false
    @Published public var remoteRelayStatusText: String = "Off"
    /// A non-fatal explanation when Remote is degraded while the local Host
    /// remains healthy. Never contains relay credentials or route material.
    @Published public var remoteRelayStatusDetail: String? = nil
    @Published public var remoteRelayAuthorizationInProgress: Bool = false

    public var onStartStop: () -> Void = {}
    /// Preserve the current recording, then open the chooser. V1 does not
    /// hot-swap the engine inside one file because that needs a durable
    /// discontinuity boundary and rollback path.
    public var onStopAndChooseMicrophone: () -> Void = {}
    /// nil selects the live macOS system default; a UID selects one explicit
    /// input device. Device changes are accepted only while capture is idle.
    public var onSelectMicrophone: (String?) -> Void = { _ in }
    /// Trigger Sparkle's check-for-updates UI. nil in previews/tests and
    /// under UI testing, where the updater isn't started.
    public var onCheckForUpdates: (() -> Void)?
    /// Install a known update (re-presents Sparkle's update sheet).
    public var onInstallUpdate: (() -> Void)?
    public var onStartDictation: () -> Void = {}
    public var onOpenWindow: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteIntoFrontmost: () -> Void = {}
    public var onOpenLastRecording: () -> Void = {}
    public var onKeepRecording: () -> Void = {}
    /// Wipe the idle pre-roll window without stopping capture.
    public var onClearPreRoll: () -> Void = {}
    public var onStopNow: () -> Void = {}
    public var onOpenSettings: () -> Void = {}
    /// Opens the pairing surface for the configured runtime role. The older
    /// name is retained as source compatibility for existing UI call sites.
    public var onOpenHostPairing: () -> Void = {}
    /// Inventory ClientState/Captures, repair safe local metadata gaps, and
    /// retry every non-security-blocked durable outbox.
    public var onRecoverAndSyncClient: () -> Void = {}
    /// Clear only the diagnostic history. Captures, outboxes, pairing, and
    /// Host trust state are deliberately outside this action.
    public var onClearClientDiagnosticLog: () -> Void = {}
    /// Open the Library's Activity surface (readiness / recovery / jobs) —
    /// the destination behind the panel's single status row.
    public var onOpenActivity: () -> Void = {}
    /// Explicit user gesture for an upgraded Host identity whose legacy
    /// Keychain ACL no longer trusts the current signed application.
    public var onAuthorizeRemoteRelay: () -> Void = {}
    public var onRevealStopRecovery: () -> Void = {}
    public var onRetryStopRecovery: () -> Void = {}
    public var onDismissStopRecovery: () -> Void = {}
    public var onRecoverRecoveryArtifact: (String) -> Void = { _ in }
    public var onRevealRecoveryArtifact: (String) -> Void = { _ in }
    public var onDiscardRecoveryArtifact: (String) -> Void = { _ in }
    /// Run a dictation mode's transform on sample text (settings "Test"
    /// button). nil when the LLM stack isn't wired (previews/tests).
    public var testDictationTransform: ((DictationMode, String) async throws -> String)?
    /// Discard the running recording (island trash button): stops capture,
    /// holds the audio through a 10s undo window, then deletes.
    public var onDiscardRecording: () -> Void = {}
    /// Cancel a pending discard — the recording stays in the library.
    public var onUndoDiscard: () -> Void = {}

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

/// The island's discard-undo state: what was discarded and how long until
/// the deletion is real.
public struct DiscardCountdown: Equatable, Sendable {
    public var durationText: String
    public var secondsRemaining: Int

    public init(durationText: String, secondsRemaining: Int) {
        self.durationText = durationText
        self.secondsRemaining = secondsRemaining
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
