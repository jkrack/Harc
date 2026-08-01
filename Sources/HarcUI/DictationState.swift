import Foundation
import Combine
import AppKit

/// How a finished dictation reached the user — drives the HUD end-state.
public struct DictationDeliveryOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Text was pasted at the cursor in the target app.
        case inserted
        /// Text was left on the clipboard only.
        case copied
        /// No delivery — an informational flash (e.g. "Mode switched to
        /// Email via link"). Renders neutrally and auto-dismisses.
        case notice
    }

    public var kind: Kind
    /// User-facing end-state line, e.g. "Inserted into Mail".
    public var message: String
    /// True when the copy fallback happened because Accessibility is missing —
    /// the HUD offers a fix action.
    public var needsAccessibility: Bool

    public init(kind: Kind, message: String, needsAccessibility: Bool = false) {
        self.kind = kind
        self.message = message
        self.needsAccessibility = needsAccessibility
    }
}

/// Observable state for the dictation flow, mirroring `RecordingState`'s role
/// for meeting capture. Drives the dictation HUD and the menu-bar pill.
@MainActor
public final class DictationState: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Waiting on the one-time microphone permission prompt.
        case requestingMic
        case listening
        /// The STT daemon was cold — the speech model is loading.
        case loadingModel
        case transcribing
        /// The mode's LLM was cold — multi-GB weights are loading. The
        /// associated value is the model's display name ("Standard", …).
        case loadingTransformModel(String)
        /// LLM post-processing per the active dictation mode.
        case transforming
        case inserting
        /// Brief end-state after delivery ("Inserted into Mail"). Display-only;
        /// a new dictation may start during it.
        case done(DictationDeliveryOutcome)
        case error(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// Recent normalized levels (0…1) for the HUD waveform, oldest → newest.
    @Published public private(set) var levelHistory: [Float] = []
    /// Transient non-fatal note (e.g. "mode fell back to raw text"). Rendered
    /// in the delivery end-state; cleared on the next fresh start.
    @Published public private(set) var notice: String?
    /// Streaming preview of the words so far while listening (#97) —
    /// best-effort, cleared on every phase exit. Display-only: the final
    /// transcript always comes from the full-clip transcribe at stop.
    @Published public private(set) var livePartialText: String?
    /// Working context captured at dictation start (Super Mode). Empty when
    /// the active mode doesn't request context or capture was skipped.
    /// Drives the HUD context indicator; cleared when the session ends.
    @Published public private(set) var context: DictationContext = .empty
    /// True when cancel needs a second click (long session guard). The HUD
    /// turns its cancel button into an explicit "Discard".
    @Published public private(set) var confirmingCancel: Bool = false
    /// The mode governing the current session when it differs from the
    /// persisted active mode (one-shot hotkey or per-app rule). Drives the
    /// HUD chip; nil when the session simply uses the active mode.
    @Published public private(set) var sessionModeOverride: DictationMode?
    /// True when `sessionModeOverride` came from a per-app activation rule
    /// (vs a one-shot mode hotkey) — the chip shows an auto glyph.
    @Published public private(set) var sessionModeViaRule: Bool = false
    /// A `harc://dictate` link awaiting user confirmation. The HUD renders
    /// a Start/Cancel prompt; the mic never opens on a bare deep link.
    @Published public private(set) var pendingDeepLink: DictationDeepLinkRequest?

    public static let levelHistoryCount = 40

    public init() {}

    /// True while a dictation is in progress (used for mutual-exclusion with
    /// meeting recording and for hotkey routing). The `.done` afterglow and
    /// `.error` are not active — a new dictation may start over them.
    public var isActive: Bool {
        switch phase {
        case .requestingMic, .listening, .loadingModel, .loadingTransformModel,
             .transcribing, .transforming, .inserting:
            return true
        case .idle, .done, .error:
            return false
        }
    }

    public func setPhase(_ newPhase: Phase) {
        phase = newPhase
        switch newPhase {
        case .idle, .done, .error:
            levelHistory = []
            context = .empty
            confirmingCancel = false
            sessionModeOverride = nil
            sessionModeViaRule = false
            livePartialText = nil
        case .requestingMic:
            notice = nil
            confirmingCancel = false
            livePartialText = nil
        case .listening, .loadingModel, .loadingTransformModel, .transcribing,
             .transforming, .inserting:
            break
        }
    }

    public func setLivePartial(_ text: String?) {
        livePartialText = text
    }

    public func setSessionModeOverride(_ mode: DictationMode?, viaRule: Bool) {
        sessionModeOverride = mode
        sessionModeViaRule = mode != nil && viaRule
    }

    public func setNotice(_ message: String?) {
        notice = message
    }

    public func setContext(_ newContext: DictationContext) {
        context = newContext
    }

    public func setPendingDeepLink(_ request: DictationDeepLinkRequest?) {
        pendingDeepLink = request
    }

    public func setConfirmingCancel(_ value: Bool) {
        confirmingCancel = value
    }

    public func pushLevel(_ value: Float) {
        levelHistory.append(value)
        if levelHistory.count > Self.levelHistoryCount {
            levelHistory.removeFirst(levelHistory.count - Self.levelHistoryCount)
        }
    }
}

// MARK: - Trigger routing

public enum DictationHotkeyEvent: Sendable {
    case keyDown
    case keyUp
}

public enum DictationAction: Equatable, Sendable {
    case start
    case stop
    case none
}

/// Pure mapping from (trigger style, key event, active?) → action. Extracted so
/// the hotkey behaviour is unit-testable without the whole controller.
public enum DictationTriggerRouter {
    public static func action(
        style: HarcPreferences.DictationTriggerStyle,
        event: DictationHotkeyEvent,
        isActive: Bool
    ) -> DictationAction {
        switch style {
        case .pushToTalk:
            switch event {
            case .keyDown: return isActive ? .none : .start
            case .keyUp: return isActive ? .stop : .none
            }
        case .toggle:
            switch event {
            case .keyDown: return isActive ? .stop : .start
            case .keyUp: return .none
            }
        }
    }
}

// MARK: - Paster seam

/// Insertion seam so `DictationController` can be tested without touching the
/// real pasteboard / Accessibility APIs.
@MainActor
public protocol DictationPasting {
    func frontmostBundleID() -> String?
    /// Localized name of the frontmost app, for dictation history. Read at
    /// the same moment as `frontmostBundleID()`.
    func frontmostAppName() -> String?
    /// Insert text into the frontmost app (clipboard + synthetic paste).
    /// Completes when the paste keystroke has actually been posted.
    func insert(_ text: String) async throws
    /// Copy without pasting (used when the target is deny-listed).
    func copyOnly(_ text: String)
}

public extension DictationPasting {
    func frontmostAppName() -> String? { nil }
}

@MainActor
public struct SystemDictationPaster: DictationPasting {
    /// Whether to restore the user's previous clipboard after the paste lands.
    private let restoreClipboard: () -> Bool

    public init(restoreClipboard: @escaping () -> Bool = { true }) {
        self.restoreClipboard = restoreClipboard
    }

    public func frontmostBundleID() -> String? { FrontmostAppPaster.frontmostBundleID() }
    public func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
    public func insert(_ text: String) async throws {
        try await FrontmostAppPaster.copyAndPaste(text, restoreClipboard: restoreClipboard())
    }
    public func copyOnly(_ text: String) { FrontmostAppPaster.copyOnly(text) }
}
