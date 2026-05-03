import SwiftUI

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
    @Published public var amplitudeHistory: [Float] = []
    /// Mirror for the panel + recording-pill consumers that DO want the
    /// flash. Kept on the bridge as well so existing bridge-observers
    /// (panel) react. Always set in lockstep with `iconState.pasteFlash`.
    @Published public private(set) var pasteFlash: PasteFlash? = nil

    public var onStartStop: () -> Void = {}
    public var onOpenWindow: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteIntoFrontmost: () -> Void = {}

    public init(recordingState: RecordingState, trayState: PostStopTrayState) {
        self.recordingState = recordingState
        self.trayState = trayState
        self.iconState = MenuBarIconState()
    }

    /// Flash the menu-bar icon for a brief moment to signal the auto-paste
    /// outcome. Replaces the legacy MenuBarFlash that was deleted with the
    /// popover. Auto-clears after `flashDuration`.
    public func flashPaste(_ outcome: PasteFlash) {
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
                    self.pasteFlash = nil
                    self.iconState.pasteFlash = nil
                }
            }
        }
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
