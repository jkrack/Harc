import Foundation

/// Test double — fires synthetic launch/terminate events on demand.
public final class FakeWorkspace: WorkspaceObserving {
    public var runningAppBundleIDs: [String] = []

    private final class Token: NSObject {}
    private var launchHandlers: [(Token, @Sendable (String) -> Void)] = []
    private var terminateHandlers: [(Token, @Sendable (String) -> Void)] = []

    public init() {}

    public func addDidLaunchObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        let token = Token()
        launchHandlers.append((token, handler))
        return token
    }

    public func addDidTerminateObserver(_ handler: @escaping @Sendable (String) -> Void) -> NSObjectProtocol {
        let token = Token()
        terminateHandlers.append((token, handler))
        return token
    }

    public func removeObserver(_ token: NSObjectProtocol) {
        if let t = token as? Token {
            launchHandlers.removeAll { $0.0 === t }
            terminateHandlers.removeAll { $0.0 === t }
        }
    }

    public func simulateLaunch(bundleID: String) {
        launchHandlers.forEach { $0.1(bundleID) }
    }

    public func simulateTerminate(bundleID: String) {
        terminateHandlers.forEach { $0.1(bundleID) }
    }
}
