import Foundation
import HarcClientStore
import HarcIdentity
import Observation
import OSLog

enum HarcMobileHostHealthStatus: Equatable {
    case unpaired
    case checking
    case connected(lastVerifiedAt: Date)
    case unavailable(lastAttemptedAt: Date)

    var title: String {
        switch self {
        case .unpaired:
            "Desktop not paired"
        case .checking:
            "Checking desktop…"
        case .connected:
            "Desktop connected"
        case .unavailable:
            "Desktop unavailable"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .unpaired:
            "No Host desktop has been adopted. Local recording is available."
        case .checking:
            "Verifying the adopted Host desktop through an authenticated connection."
        case .connected:
            "The adopted Host desktop is authenticated and reachable."
        case .unavailable:
            "The adopted Host desktop could not be reached. Local recording remains available and transfer will retry."
        }
    }
}

@MainActor
@Observable
final class HarcMobileHostHealthCoordinator {
    typealias Probe = @MainActor () async throws -> Void

    private static let logger = Logger(
        subsystem: "com.harc.HarcMobile",
        category: "host-health"
    )

    private(set) var status: HarcMobileHostHealthStatus
    private(set) var isChecking = false

    private let probe: Probe
    private let pollingInterval: Duration
    private var monitoringTask: Task<Void, Never>?

    convenience init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL,
        pollingInterval: Duration = .seconds(30)
    ) {
        let hasActiveAdoption = (try? store.activeAdoption()) != nil
        self.init(
            hasActiveAdoption: hasActiveAdoption,
            pollingInterval: pollingInterval
        ) {
            let opened = try await HarcMobileHostSessionConnector.open(
                identity: identity,
                store: store,
                routeURL: routeURL
            )
            do {
                try await opened.connection.shutdownGracefully()
            } catch {
                await opened.connection.shutdownImmediately()
                throw error
            }
        }
    }

    init(
        hasActiveAdoption: Bool,
        pollingInterval: Duration = .seconds(30),
        probe: @escaping Probe
    ) {
        status = hasActiveAdoption ? .checking : .unpaired
        self.pollingInterval = pollingInterval
        self.probe = probe
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let pollingInterval = self?.pollingInterval else {
                    return
                }
                do {
                    try await Task.sleep(for: pollingInterval)
                } catch {
                    return
                }
                await self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        if case .unpaired = status {
            status = .checking
        }
        defer { isChecking = false }

        do {
            try await probe()
            status = .connected(lastVerifiedAt: .now)
        } catch HarcMobileHostSessionConnectorError.notPaired {
            status = .unpaired
        } catch {
            Self.logger.info(
                "Authenticated Host health check failed: \(String(reflecting: error), privacy: .public)"
            )
            status = .unavailable(lastAttemptedAt: .now)
        }
    }
}
