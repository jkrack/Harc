import Foundation

/// Keeps the STT daemon's speech model resident so the first dictation after
/// a break isn't slowed by a cold load. The daemon idle-stops 30 minutes
/// after its last request; any request resets that clock, so a periodic
/// `status` ping is enough to hold it warm.
///
/// Deliberately never launches the daemon — it only pings when the daemon is
/// already up (`isDaemonRunning`). If the daemon isn't running there's
/// nothing to keep warm, and dictation's own `ensureRunning()` handles the
/// launch on first use.
@MainActor
public final class DictationKeepWarmController {
    /// Well under the daemon's 30-minute idle timeout.
    public static let defaultInterval: TimeInterval = 10 * 60

    private let interval: TimeInterval
    private let isDaemonRunning: () async -> Bool
    private let ping: () async -> Void
    private var task: Task<Void, Never>?
    /// Total pings sent — exposed for tests.
    public private(set) var pingCount = 0

    public init(
        interval: TimeInterval = DictationKeepWarmController.defaultInterval,
        isDaemonRunning: @escaping () async -> Bool,
        ping: @escaping () async -> Void
    ) {
        self.interval = interval
        self.isDaemonRunning = isDaemonRunning
        self.ping = ping
    }

    public var isRunning: Bool { task != nil }

    /// Start or stop the ping loop to match the preference.
    public func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.interval))
                guard !Task.isCancelled else { return }
                // Only ping a daemon that's already up — never launch one.
                if await self.isDaemonRunning() {
                    await self.ping()
                    self.pingCount += 1
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
