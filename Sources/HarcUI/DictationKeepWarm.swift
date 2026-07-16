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
///
/// An optional `activeWindow` bounds how long after the last dictation
/// (`noteActivity()`) pings continue — SuperWhisper's "model active duration"
/// analog. nil = ping for as long as the loop is enabled.
@MainActor
public final class DictationKeepWarmController {
    /// Well under the daemon's 30-minute idle timeout.
    public static let defaultInterval: TimeInterval = 10 * 60

    private let interval: TimeInterval
    private let isDaemonRunning: () async -> Bool
    private let ping: () async -> Void
    private let now: () -> Date
    private var task: Task<Void, Never>?
    /// Seconds after `lastActivity` to keep pinging; nil = unbounded.
    private var activeWindow: TimeInterval?
    private var lastActivity: Date
    /// Total pings sent — exposed for tests.
    public private(set) var pingCount = 0

    public init(
        interval: TimeInterval = DictationKeepWarmController.defaultInterval,
        activeWindow: TimeInterval? = nil,
        isDaemonRunning: @escaping () async -> Bool,
        ping: @escaping () async -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.interval = interval
        self.activeWindow = activeWindow
        self.isDaemonRunning = isDaemonRunning
        self.ping = ping
        self.now = now
        self.lastActivity = now()
    }

    public var isRunning: Bool { task != nil }

    /// Start or stop the ping loop to match the preference.
    public func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    /// Update how long after the last dictation pings continue.
    public func setActiveWindow(_ window: TimeInterval?) {
        activeWindow = window
    }

    /// Record a dictation — re-opens the active window.
    public func noteActivity() {
        lastActivity = now()
    }

    /// True when the active window (if any) still covers this moment.
    public var withinActiveWindow: Bool {
        guard let activeWindow else { return true }
        return now().timeIntervalSince(lastActivity) <= activeWindow
    }

    private func start() {
        guard task == nil else { return }
        lastActivity = now()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.interval))
                guard !Task.isCancelled else { return }
                // Past the active window: idle quietly. The loop keeps
                // running so the next noteActivity() resumes pinging.
                guard self.withinActiveWindow else { continue }
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
