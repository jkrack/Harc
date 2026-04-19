import Foundation

@MainActor
public final class MeetingDetector {
    public protocol Delegate: AnyObject {
        /// Called on main when a monitored app's launch was observed and should
        /// be surfaced to the user (allowlisted, enabled, debounced, not
        /// suppressed by an active recording).
        func meetingDetector(_ detector: MeetingDetector, didDetect app: MeetingApp)
    }

    public weak var delegate: Delegate?

    private let workspace: any WorkspaceObserving
    private let isGloballyEnabled: () -> Bool
    private let isAppEnabled: (MeetingApp) -> Bool
    private let isRecordingInProgress: () -> Bool

    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?
    private var activeDetections: Set<String> = []

    public init(
        workspace: any WorkspaceObserving,
        isGloballyEnabled: @escaping () -> Bool,
        isAppEnabled: @escaping (MeetingApp) -> Bool,
        isRecordingInProgress: @escaping () -> Bool
    ) {
        self.workspace = workspace
        self.isGloballyEnabled = isGloballyEnabled
        self.isAppEnabled = isAppEnabled
        self.isRecordingInProgress = isRecordingInProgress
    }

    public func start() {
        guard isGloballyEnabled() else { return }
        guard launchToken == nil else { return }

        // Pre-seed: apps already running when detection starts are silently
        // added to the debounce set so we don't prompt about them until they
        // quit-and-relaunch.
        for bundleID in workspace.runningAppBundleIDs {
            if MeetingCatalog.entry(forBundleID: bundleID) != nil {
                activeDetections.insert(bundleID)
            }
        }

        launchToken = workspace.addDidLaunchObserver { [weak self] id in
            Task { @MainActor in self?.handleLaunch(bundleID: id) }
        }
        terminateToken = workspace.addDidTerminateObserver { [weak self] id in
            Task { @MainActor in self?.handleTerminate(bundleID: id) }
        }
    }

    public func stop() {
        if let t = launchToken { workspace.removeObserver(t); launchToken = nil }
        if let t = terminateToken { workspace.removeObserver(t); terminateToken = nil }
        activeDetections.removeAll()
    }

    /// Mark a detection as user-acknowledged. Prevents re-prompting until the
    /// source app terminates and relaunches.
    public func markHandled(bundleID: String) {
        activeDetections.insert(bundleID)
    }

    private func handleLaunch(bundleID: String) {
        guard isGloballyEnabled() else { return }
        guard let app = MeetingCatalog.entry(forBundleID: bundleID) else { return }
        guard isAppEnabled(app) else { return }
        guard !activeDetections.contains(bundleID) else { return }
        guard !isRecordingInProgress() else {
            activeDetections.insert(bundleID)
            return
        }
        activeDetections.insert(bundleID)
        delegate?.meetingDetector(self, didDetect: app)
    }

    private func handleTerminate(bundleID: String) {
        activeDetections.remove(bundleID)
        // Also drop debounce for the catalog entry's primary + aliases, so a
        // relaunch of either variant fires a fresh prompt.
        if let app = MeetingCatalog.entry(forBundleID: bundleID) {
            activeDetections.remove(app.bundleID)
            for alias in app.aliasBundleIDs { activeDetections.remove(alias) }
        }
    }
}
