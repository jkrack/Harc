import AppKit

/// Production adapter over `NSWorkspace.shared.notificationCenter`.
/// Note: NSWorkspace app-launch observation is public API requiring no
/// additional entitlements on unsandboxed, direct-distribution macOS apps.
public final class SystemWorkspace: WorkspaceObserving, @unchecked Sendable {
    public static let shared = SystemWorkspace()

    public var runningAppBundleIDs: [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    }

    public func addDidLaunchObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            handler(id)
        }
    }

    public func addDidTerminateObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            handler(id)
        }
    }

    public func removeObserver(_ token: NSObjectProtocol) {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
}
