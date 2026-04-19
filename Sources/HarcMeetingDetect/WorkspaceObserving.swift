import Foundation

/// A seam over `NSWorkspace` so detection can be unit-tested with a fake.
public protocol WorkspaceObserving: AnyObject {
    /// Snapshot of currently running apps' bundle IDs (nils filtered).
    var runningAppBundleIDs: [String] { get }

    /// Register a handler invoked with each launched app's bundle ID.
    /// Returned token identifies the subscription for `removeObserver`.
    func addDidLaunchObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol

    /// Register a handler invoked with each terminated app's bundle ID.
    func addDidTerminateObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol

    /// Remove a handler registered via one of the `add…Observer` methods.
    func removeObserver(_ token: NSObjectProtocol)
}
