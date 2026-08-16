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
    typealias HostIdentityProbe = @MainActor () async throws -> String?

    private static let logger = Logger(
        subsystem: "com.harc.HarcMobile",
        category: "host-health"
    )

    private(set) var status: HarcMobileHostHealthStatus
    private(set) var isChecking = false
    private(set) var lastVerifiedAt: Date?
    private(set) var hostDisplayName: String?

    private let hostIdentityProbe: HostIdentityProbe
    private let pollingInterval: Duration
    private let persistLastVerifiedAt: @MainActor (Date) -> Void
    private let persistHostDisplayName: @MainActor (String) -> Void
    private var monitoringTask: Task<Void, Never>?

    convenience init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL,
        pollingInterval: Duration = .seconds(30)
    ) {
        let activeAdoption = try? store.activeAdoption()
        let hostAuthorityID = activeAdoption?.tuple.hostAuthorityID.description
        self.init(
            hostIdentityProbe: {
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
                return opened.hostDisplayName
            },
            hasActiveAdoption: activeAdoption != nil,
            lastVerifiedAt: hostAuthorityID.flatMap {
                HarcMobileHostPresentationStore.lastVerifiedAt(
                    hostAuthorityID: $0
                )
            },
            hostDisplayName: hostAuthorityID.flatMap {
                HarcMobileHostPresentationStore.displayName(
                    hostAuthorityID: $0
                )
            },
            pollingInterval: pollingInterval,
            persistLastVerifiedAt: { date in
                guard let current = try? store.activeAdoption() else { return }
                HarcMobileHostPresentationStore.saveLastVerifiedAt(
                    date,
                    hostAuthorityID:
                        current.tuple.hostAuthorityID.description
                )
            },
            persistHostDisplayName: { displayName in
                guard let current = try? store.activeAdoption() else { return }
                HarcMobileHostPresentationStore.saveDisplayName(
                    displayName,
                    hostAuthorityID:
                        current.tuple.hostAuthorityID.description
                )
            }
        )
    }

    convenience init(
        hasActiveAdoption: Bool,
        lastVerifiedAt: Date? = nil,
        hostDisplayName: String? = nil,
        pollingInterval: Duration = .seconds(30),
        persistLastVerifiedAt: @escaping @MainActor (Date) -> Void = { _ in },
        persistHostDisplayName: @escaping @MainActor (String) -> Void = { _ in },
        probe: @escaping Probe
    ) {
        self.init(
            hostIdentityProbe: {
                try await probe()
                return nil
            },
            hasActiveAdoption: hasActiveAdoption,
            lastVerifiedAt: lastVerifiedAt,
            hostDisplayName: hostDisplayName,
            pollingInterval: pollingInterval,
            persistLastVerifiedAt: persistLastVerifiedAt,
            persistHostDisplayName: persistHostDisplayName
        )
    }

    init(
        hostIdentityProbe: @escaping HostIdentityProbe,
        hasActiveAdoption: Bool,
        lastVerifiedAt: Date? = nil,
        hostDisplayName: String? = nil,
        pollingInterval: Duration = .seconds(30),
        persistLastVerifiedAt: @escaping @MainActor (Date) -> Void = { _ in },
        persistHostDisplayName: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        status = hasActiveAdoption ? .checking : .unpaired
        self.lastVerifiedAt = hasActiveAdoption ? lastVerifiedAt : nil
        self.hostDisplayName = hasActiveAdoption ? hostDisplayName : nil
        self.pollingInterval = pollingInterval
        self.persistLastVerifiedAt = persistLastVerifiedAt
        self.persistHostDisplayName = persistHostDisplayName
        self.hostIdentityProbe = hostIdentityProbe
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
            let probedHostName = try await hostIdentityProbe()
            let verifiedHostName = probedHostName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let verifiedHostName, !verifiedHostName.isEmpty {
                hostDisplayName = verifiedHostName
                persistHostDisplayName(verifiedHostName)
            }
            let verifiedAt = Date.now
            lastVerifiedAt = verifiedAt
            persistLastVerifiedAt(verifiedAt)
            status = .connected(lastVerifiedAt: verifiedAt)
        } catch HarcMobileHostSessionConnectorError.notPaired {
            lastVerifiedAt = nil
            hostDisplayName = nil
            status = .unpaired
        } catch {
            Self.logger.info(
                "Authenticated Host health check failed: \(String(reflecting: error), privacy: .public)"
            )
            status = .unavailable(lastAttemptedAt: .now)
        }
    }
}
