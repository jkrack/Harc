import Foundation
import Combine

/// Observable state for the dictation flow, mirroring `RecordingState`'s role
/// for meeting capture. Drives the dictation HUD and the menu-bar pill.
@MainActor
public final class DictationState: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case inserting
        case error(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// Recent normalized levels (0…1) for the HUD waveform, oldest → newest.
    @Published public private(set) var levelHistory: [Float] = []

    public static let levelHistoryCount = 40

    public init() {}

    /// True while a dictation is in progress (used for mutual-exclusion with
    /// meeting recording and for hotkey routing).
    public var isActive: Bool {
        switch phase {
        case .listening, .transcribing, .inserting: return true
        case .idle, .error: return false
        }
    }

    public func setPhase(_ newPhase: Phase) {
        phase = newPhase
        if case .idle = newPhase { levelHistory = [] }
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
    /// Insert text into the frontmost app (clipboard + synthetic paste).
    func insert(_ text: String) throws
    /// Copy without pasting (used when the target is deny-listed).
    func copyOnly(_ text: String)
}

@MainActor
public struct SystemDictationPaster: DictationPasting {
    public init() {}
    public func frontmostBundleID() -> String? { FrontmostAppPaster.frontmostBundleID() }
    public func insert(_ text: String) throws { try FrontmostAppPaster.copyAndPaste(text) }
    public func copyOnly(_ text: String) { FrontmostAppPaster.copyOnly(text) }
}
