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

    @Published public var frontmostAppName: String? = nil
    @Published public var amplitudeHistory: [Float] = []
    /// Brief tint signal for the menu-bar bars icon after auto-paste runs.
    /// Cleared automatically ~1.2s after `flashPaste(_:)`.
    @Published public private(set) var pasteFlash: PasteFlash? = nil

    public var onStartStop: () -> Void = {}
    public var onOpenWindow: () -> Void = {}
    public var onCopyLastTranscript: () -> Void = {}
    public var onPasteIntoFrontmost: () -> Void = {}

    public init(recordingState: RecordingState, trayState: PostStopTrayState) {
        self.recordingState = recordingState
        self.trayState = trayState
    }

    /// Flash the menu-bar icon for a brief moment to signal the auto-paste
    /// outcome. Replaces the legacy MenuBarFlash that was deleted with the
    /// popover. Auto-clears after `flashDuration`.
    public func flashPaste(_ outcome: PasteFlash) {
        pasteFlash = outcome
        let captureToken = UUID()
        currentFlashToken = captureToken
        Task { [weak self, captureToken] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            // Only clear if no newer flash superseded us.
            if self.currentFlashToken == captureToken {
                await MainActor.run { self.pasteFlash = nil }
            }
        }
    }

    private var currentFlashToken: UUID = UUID()
}

/// Outcome of a post-stop auto-paste run, used as a one-shot tint hint
/// on the menu-bar bars icon.
public enum PasteFlash: Sendable, Equatable {
    case success
    case skipped
    case failure
}
