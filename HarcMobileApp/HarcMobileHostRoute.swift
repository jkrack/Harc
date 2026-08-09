import Foundation
import HarcAudioMobile
import HarcClientTransport
import HarcRemoteTransport
import HarcProtocol
@preconcurrency import Network

struct HarcMobileHostRoute: Codable, Equatable, Sendable {
    let host: String
    let port: UInt16
    let serverHostname: String
    let relay: HarcRemoteRelayRouteV1?

    init(ticket: PairingTicketV1) throws {
        guard let endpoint = ticket.endpoints.first(where: {
            $0.kind == .dnsHost
        }),
              let host = endpoint.textValue,
              !host.isEmpty,
              endpoint.port > 0 else {
            throw HarcMobileHostRouteError.noDNSRoute
        }
        self.host = host
        port = endpoint.port
        serverHostname = host
        if let relayEndpoint = ticket.endpoints.first(where: {
            $0.kind == .remoteRelay
        }) {
            let decoded = try PairingRelayEndpointV1.decode(relayEndpoint)
            guard let origin = URL(
                string: "https://\(decoded.serviceHost)"
            ) else {
                throw HarcMobileHostRouteError.invalidResolvedRoute
            }
            relay = try HarcRemoteRelayRouteV1(
                serviceOrigin: origin,
                hostRouteID: decoded.hostRouteID,
                deviceRouteID: decoded.admissionRouteID,
                capability: decoded.capability
            )
        } else {
            relay = nil
        }
    }

    init(
        host: String,
        port: UInt16,
        serverHostname: String? = nil,
        relay: HarcRemoteRelayRouteV1? = nil
    ) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, port > 0 else {
            throw HarcMobileHostRouteError.invalidResolvedRoute
        }
        self.host = host
        self.port = port
        self.serverHostname = serverHostname ?? host
        self.relay = relay
    }
}

enum HarcMobileHostRouteError: LocalizedError {
    case noDNSRoute
    case invalidResolvedRoute
    case resolutionFailed

    var errorDescription: String? {
        switch self {
        case .noDNSRoute:
            "The pairing code does not contain a directly connectable Host route."
        case .invalidResolvedRoute:
            "Harc discovered an invalid Host route."
        case .resolutionFailed:
            "Harc could not resolve the discovered Host service."
        }
    }
}

/// Bounded adopted-host route recovery for completion events and foreground
/// retries. Bonjour fields are never trusted here: callers still establish
/// pinned TLS, validate HostInfo against the persisted adoption, and open an
/// authenticated application session before saving any returned route.
enum HarcMobileBonjourHostRouteResolver {
    static let recoveryTimeout: Duration = .seconds(5)

    static func discover(
        timeout: Duration = recoveryTimeout
    ) async -> [HarcMobileHostRoute] {
        let browser = HarcBonjourDiscoveryBrowserV1()
        return await withTaskGroup(
            of: [HarcMobileHostRoute].self,
            returning: [HarcMobileHostRoute].self
        ) { group in
            group.addTask {
                do {
                    let events = try await browser.start()
                    for await event in events {
                        try Task.checkCancellation()
                        guard case .snapshot(let snapshot) = event else {
                            continue
                        }
                        var routes: [HarcMobileHostRoute] = []
                        for candidate in snapshot.candidates
                        where candidate.hints.protocolMajor == 1
                            && candidate.hints.protocolMinor == 0 {
                            if let route = try? await resolve(
                                candidate.endpoint
                            ), !routes.contains(route) {
                                routes.append(route)
                            }
                        }
                        if !routes.isEmpty { return routes }
                    }
                } catch {}
                return []
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let routes = await group.next() ?? []
            group.cancelAll()
            await browser.cancel()
            return routes
        }
    }

    static func route(
        fromResolvedEndpoint endpoint: NWEndpoint
    ) throws -> HarcMobileHostRoute {
        guard case .hostPort(let host, let port) = endpoint else {
            throw HarcMobileHostRouteError.invalidResolvedRoute
        }
        return try HarcMobileHostRoute(
            host: String(describing: host),
            port: port.rawValue
        )
    }

    private static func resolve(
        _ endpoint: NWEndpoint
    ) async throws -> HarcMobileHostRoute {
        let connection = NWConnection(to: endpoint, using: .tcp)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = HarcMobileRouteResolutionGate(
                    connection: connection,
                    continuation: continuation
                )
                connection.stateUpdateHandler = { state in
                    Task { await gate.received(state) }
                }
                connection.start(
                    queue: DispatchQueue(
                        label: "com.harc.mobile-route-resolution"
                    )
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private actor HarcMobileRouteResolutionGate {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<
        HarcMobileHostRoute,
        any Error
    >?

    init(
        connection: NWConnection,
        continuation: CheckedContinuation<
            HarcMobileHostRoute,
            any Error
        >
    ) {
        self.connection = connection
        self.continuation = continuation
    }

    func received(_ state: NWConnection.State) {
        guard continuation != nil else { return }
        switch state {
        case .ready:
            guard let endpoint = connection.currentPath?.remoteEndpoint else {
                finish(.failure(HarcMobileHostRouteError.resolutionFailed))
                return
            }
            do {
                finish(.success(
                    try HarcMobileBonjourHostRouteResolver.route(
                        fromResolvedEndpoint: endpoint
                    )
                ))
            } catch {
                finish(.failure(error))
            }
        case .failed:
            finish(.failure(HarcMobileHostRouteError.resolutionFailed))
        case .cancelled:
            finish(.failure(CancellationError()))
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            finish(.failure(HarcMobileHostRouteError.resolutionFailed))
        }
    }

    private func finish(
        _ result: Result<HarcMobileHostRoute, any Error>
    ) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}

enum HarcMobileHostRouteStore {
    static func load(from url: URL) throws -> HarcMobileHostRoute {
        try JSONDecoder().decode(
            HarcMobileHostRoute.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    static func save(_ route: HarcMobileHostRoute, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(route).write(to: url, options: .atomic)
        try FoundationHarcMobileCaptureStorageAttributes().applyAndVerify(
            .transferArtifact,
            to: url
        )
    }
}
