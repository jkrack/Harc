#if canImport(Network)
import Foundation

/// Periodically removes Host upload staging that is safely beyond its durable
/// resume window. Maintenance is deliberately fail-soft: an unavailable disk
/// must not take the resident Host transport offline, but the most recent error
/// remains observable through `status()`.
package actor HarcHostStagingMaintenanceScheduler {
    package static let defaultInterval: Duration = .seconds(6 * 60 * 60)

    private let interval: Duration
    private let reap: @Sendable () async throws -> Int
    private let sleep: @Sendable (Duration) async throws -> Void
    private let log: @Sendable (String) -> Void
    private var task: Task<Void, Never>?
    private var reaping = false
    private var lastAttemptAt: Date?
    private var lastSuccessAt: Date?
    private var lastErrorDescription: String?
    private var totalReapedCount = 0

    package init(
        interval: Duration = HarcHostStagingMaintenanceScheduler.defaultInterval,
        reap: @escaping @Sendable () async throws -> Int,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        log: @escaping @Sendable (String) -> Void = {
            FileHandle.standardError.write(Data($0.utf8))
        }
    ) {
        self.interval = interval
        self.reap = reap
        self.sleep = sleep
        self.log = log
    }

    /// Starts with an immediate pass, then sleeps between later passes.
    package func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Wake is an explicit self-healing trigger. The in-flight guard keeps a
    /// periodic pass and a wake pass from reaping concurrently.
    package func handleSystemWake() async {
        await runNow()
    }

    package func stop() async {
        let stopping = task
        task = nil
        stopping?.cancel()
        await stopping?.value
    }

    package func runNow(at date: Date = Date()) async {
        guard !reaping else { return }
        reaping = true
        lastAttemptAt = date
        defer { reaping = false }

        do {
            let count = try await reap()
            lastSuccessAt = date
            lastErrorDescription = nil
            totalReapedCount += count
            if count > 0 {
                log("harc-host: reaped \(count) expired staging upload(s)\n")
            }
        } catch {
            // Status is safe to surface in diagnostics. Do not retain an
            // arbitrary localized error that may contain private local paths.
            lastErrorDescription = String(
                reflecting: Swift.type(of: error)
            )
            log("harc-host: staging maintenance failed; it will retry\n")
        }
    }

    package func status() -> HarcHostStagingMaintenanceStatus {
        HarcHostStagingMaintenanceStatus(
            isRunning: task != nil,
            isReaping: reaping,
            lastAttemptAt: lastAttemptAt,
            lastSuccessAt: lastSuccessAt,
            lastErrorDescription: lastErrorDescription,
            totalReapedCount: totalReapedCount
        )
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await runNow()
            do {
                try await sleep(interval)
            } catch {
                break
            }
        }
    }
}

public struct HarcHostStagingMaintenanceStatus: Equatable, Sendable {
    public let isRunning: Bool
    public let isReaping: Bool
    public let lastAttemptAt: Date?
    public let lastSuccessAt: Date?
    public let lastErrorDescription: String?
    public let totalReapedCount: Int
}
#endif
