import Darwin
import Foundation
import HarcClientStore
import HarcClientTransport
import HarcRemoteTransport
import HarcIdentity
import HarcProtocol
import HarcTransfer

struct HarcDesktopHostRoute: Codable, Equatable, Sendable {
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
            throw HarcDesktopHostConnectionError.noDNSRoute
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
                throw HarcDesktopHostConnectionError.noDNSRoute
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
            throw HarcDesktopHostConnectionError.noDNSRoute
        }
        self.host = host
        self.port = port
        self.serverHostname = serverHostname ?? host
        self.relay = relay
    }
}

enum HarcDesktopHostRouteStore {
    static func load(from url: URL) throws -> HarcDesktopHostRoute {
        try JSONDecoder().decode(
            HarcDesktopHostRoute.self,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    static func save(_ route: HarcDesktopHostRoute, to url: URL) throws {
        guard url.isFileURL else {
            throw HarcDesktopHostConnectionError.unsafeRoutePath
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(route).write(to: url, options: .atomic)
        let routeDescriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard routeDescriptor >= 0 else {
            throw HarcDesktopHostConnectionError.routePersistenceFailed
        }
        defer { Darwin.close(routeDescriptor) }
        var routeInformation = stat()
        guard fstat(routeDescriptor, &routeInformation) == 0,
              routeInformation.st_mode & S_IFMT == S_IFREG,
              routeInformation.st_uid == geteuid(),
              fchmod(routeDescriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(routeDescriptor) == 0 else {
            throw HarcDesktopHostConnectionError.routePersistenceFailed
        }
        let directoryDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw HarcDesktopHostConnectionError.routePersistenceFailed
        }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw HarcDesktopHostConnectionError.routePersistenceFailed
        }
    }
}

struct HarcDesktopOpenedHostConnection: Sendable {
    let connection: HarcPinnedGRPCConnection
    let adoption: ValidatedClientAdoptionEvidence
    let session: HarcOpenedClientSession
    let negotiated: HarcValidatedNegotiatedCapabilitiesV1
}

enum HarcDesktopHostSessionConnector {
    static func open(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL
    ) async throws -> HarcDesktopOpenedHostConnection {
        guard let snapshot = try store.activeAdoption() else {
            throw HarcDesktopHostConnectionError.notPaired
        }
        let adoption = try HarcPersistedAdoptionValidatorV1.validate(
            snapshot,
            devicePublicKey: identity.publicKey
        )
        let route: HarcDesktopHostRoute
        do {
            route = try HarcDesktopHostRouteStore.load(from: routeURL)
        } catch {
            throw HarcDesktopHostConnectionError.notPaired
        }
        let trust = HarcTransportTrustCoordinator(
            adoptedPersistence:
                HarcTransferStoreTransportTrustPersistenceV1(store: store)
        )
        let connection: HarcPinnedGRPCConnection
        do {
            connection = try await HarcPinnedGRPCConnection.connect(
                host: route.host,
                port: Int(route.port),
                serverHostname: route.serverHostname,
                trustCoordinator: trust
            )
        } catch {
            guard let relay = route.relay else {
                throw error
            }
            let tunnel = try await HarcRemoteRelayClientTunnel.open(
                route: relay
            )
            do {
                connection = try await HarcPinnedGRPCConnection.connect(
                    host: tunnel.localHost,
                    port: Int(tunnel.localPort),
                    serverHostname: route.serverHostname,
                    trustCoordinator: trust,
                    transportLifetime: tunnel
                )
            } catch {
                await tunnel.shutdown()
                throw error
            }
        }
        do {
            let policy = try capabilityPolicy()
            let client = HarcBootstrapClient(
                rpc: connection,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let negotiated = try await client.negotiateCapabilities(
                clientOffer: try capabilityOffer(policy: policy),
                expectation: HarcBootstrapTrustExpectation(
                    adoption: adoption
                )
            )
            let session = try await client.openSession(
                adoption: adoption,
                negotiatedCapabilities: negotiated.negotiated,
                deviceSigner: identity
            )
            return HarcDesktopOpenedHostConnection(
                connection: connection,
                adoption: adoption,
                session: session,
                negotiated: negotiated.negotiated
            )
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    static func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [.cafALAC]
        )
    }

    static func capabilityOffer(
        policy: HarcCapabilityPolicyV1
    ) throws -> HarcValidatedCapabilityOfferV1 {
        var offer = Harc_V1_CapabilityOfferV1()
        offer.protocolMajor = 1
        offer.minimumProtocolMinor = 0
        offer.maximumProtocolMinor = 0
        offer.supportedDescriptorSchemaIds = [
            ChunkDescriptorSchema.v1.rawValue,
        ]
        offer.supportedEncodings = [
            Harc_V1_LosslessEncodingConfigurationV1(.cafALAC),
        ]
        offer.supportedCanonicalFormats = [
            Harc_V1_CanonicalPCMFormatV1(.harcV1),
        ]
        return try HarcValidatedCapabilityOfferV1(offer, policy: policy)
    }
}

enum HarcDesktopHostConnectionError: LocalizedError {
    case noDNSRoute
    case unsafeRoutePath
    case routePersistenceFailed
    case notPaired

    var errorDescription: String? {
        switch self {
        case .noDNSRoute:
            "The pairing code does not contain a directly connectable Host route."
        case .unsafeRoutePath:
            "The saved Host route path is unsafe."
        case .routePersistenceFailed:
            "The paired Host route could not be stored durably."
        case .notPaired:
            "This Mac is not paired with a Harc Host."
        }
    }
}
