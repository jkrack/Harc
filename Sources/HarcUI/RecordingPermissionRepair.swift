import AppKit
import AVFoundation
import CoreGraphics
import Foundation

/// The TCC services Harc depends on. `rawValue` is the `tccutil` service
/// name — do not rename without checking `tccutil reset <service>`.
public enum RecordingPermissionService: String, CaseIterable, Sendable {
    case microphone = "Microphone"
    case screenCapture = "ScreenCapture"
    case accessibility = "Accessibility"

    public var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenCapture: return "Screen & System Audio Recording"
        case .accessibility: return "Accessibility"
        }
    }

    /// What breaks without it, in the user's terms.
    public var purpose: String {
        switch self {
        case .microphone:
            return "Records your voice for meetings and dictation."
        case .screenCapture:
            return "Captures the other side of a call, so remote participants appear in the transcript."
        case .accessibility:
            return "Lets Harc paste dictated text into the app you're using, and cancel with Esc."
        }
    }

    /// Granting Screen Recording only takes effect after the app restarts —
    /// macOS keeps the old answer for the life of the process.
    public var requiresRelaunchAfterGrant: Bool {
        self == .screenCapture
    }

    /// The System Settings pane that holds this toggle. Used when the
    /// in-process request API would be a no-op (see `canPromptInProcess`).
    public var settingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenCapture:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    public var isGranted: Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenCapture:
            return CGPreflightScreenCaptureAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Whether asking in-process can still produce a system prompt.
    ///
    /// macOS shows each of these prompts at most once per app install. Once
    /// the user has answered — or simply been asked and dismissed — the
    /// request API returns silently and nothing appears on screen. Calling it
    /// anyway is how a "Grant" button becomes a button that does nothing, so
    /// callers must fall back to `settingsURL` when this is false.
    public var canPromptInProcess: Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .screenCapture, .accessibility:
            // Neither exposes a "not determined" state; both prompt only on
            // first ask, so treat an ungranted state as needing System
            // Settings. A redundant trip there is harmless; a dead button is not.
            return false
        }
    }
}

/// A snapshot of every grant Harc needs, read together so callers can't
/// check one and forget another.
public struct PermissionSnapshot: Equatable, Sendable {
    public var microphone: Bool
    public var screenCapture: Bool
    public var accessibility: Bool

    public static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: RecordingPermissionService.microphone.isGranted,
            screenCapture: RecordingPermissionService.screenCapture.isGranted,
            accessibility: RecordingPermissionService.accessibility.isGranted
        )
    }

    public func isGranted(_ service: RecordingPermissionService) -> Bool {
        switch service {
        case .microphone: return microphone
        case .screenCapture: return screenCapture
        case .accessibility: return accessibility
        }
    }

    public var missing: [RecordingPermissionService] {
        RecordingPermissionService.allCases.filter { !isGranted($0) }
    }

    /// Recording needs a mic; dictation insertion needs Accessibility. Screen
    /// capture is excluded deliberately — without it Harc still records the
    /// user's own voice, so it degrades rather than breaks, and plenty of
    /// people decline it on purpose.
    public var coreGrantsIntact: Bool {
        microphone && accessibility
    }
}

struct RecordingPermissionRepairPlan: Equatable {
    var bundleID: String
    var services: [RecordingPermissionService]

    var tccutilArguments: [[String]] {
        services.map { ["reset", $0.rawValue, bundleID] }
    }

    static func current(
        bundleID: String? = Bundle.main.bundleIdentifier,
        services: [RecordingPermissionService] = RecordingPermissionService.allCases
    ) -> RecordingPermissionRepairPlan? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return RecordingPermissionRepairPlan(bundleID: bundleID, services: services)
    }
}

public enum RecordingPermissionRepair {
    /// Set when a reset runs, cleared once the setup flow has been offered
    /// again. A reset deliberately destroys every grant, so the next launch
    /// must show the repair path regardless of whether the once-per-build
    /// re-offer was already spent — otherwise the user relaunches into an app
    /// that silently cannot record.
    public static let pendingRepairKey = "harc.permissionRepairPending"

    enum Error: Swift.Error, LocalizedError, Equatable {
        case missingBundleID
        case commandFailed(service: RecordingPermissionService, status: Int32)

        var errorDescription: String? {
            switch self {
            case .missingBundleID:
                return "Harc could not determine its app identifier."
            case .commandFailed(let service, let status):
                return "\(service.displayName) reset failed with status \(status)."
            }
        }
    }

    static func reset(
        plan: RecordingPermissionRepairPlan,
        defaults: UserDefaults = .standard
    ) throws {
        for service in plan.services {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service.rawValue, plan.bundleID]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw Error.commandFailed(service: service, status: process.terminationStatus)
            }
        }
        defaults.set(true, forKey: pendingRepairKey)
    }

    /// Schedule this app to reopen after it quits.
    ///
    /// Resetting TCC requires a relaunch to take effect, but Harc is
    /// `LSUIElement` — quitting leaves no Dock icon and no window, so a user
    /// who has just been dropped into System Settings has no obvious way
    /// back. A detached `open` that fires after we exit closes that trap.
    /// The child is deliberately not a subprocess of anything we own: it has
    /// to outlive us.
    @discardableResult
    public static func scheduleRelaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        delaySeconds: Int = 1
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep \(delaySeconds); /usr/bin/open \"\(bundleURL.path)\"",
        ]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    public static func openSettings(for service: RecordingPermissionService) {
        guard let url = service.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    static func openScreenCaptureSettings() {
        openSettings(for: .screenCapture)
    }
}
