import Foundation
import HarcClientStore
import HarcClientTransport
import HarcRemoteTransport
import HarcIdentity
import HarcProtocol
import HarcTransfer

struct HarcMobileOpenedHostConnection: Sendable {
    let connection: HarcPinnedGRPCConnection
    let adoption: ValidatedClientAdoptionEvidence
    let session: HarcOpenedClientSession
    let negotiated: HarcValidatedNegotiatedCapabilitiesV1
    let hostDisplayName: String
}

enum HarcMobileHostSessionConnector {
    static func open(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL
    ) async throws -> HarcMobileOpenedHostConnection {
        guard let snapshot = try store.activeAdoption() else {
            throw HarcMobileHostSessionConnectorError.notPaired
        }
        let adoption = try HarcPersistedAdoptionValidatorV1.validate(
            snapshot,
            devicePublicKey: identity.publicKey
        )
        let persistedRoute: HarcMobileHostRoute
        do {
            persistedRoute = try HarcMobileHostRouteStore.load(from: routeURL)
        } catch {
            throw HarcMobileHostSessionConnectorError.notPaired
        }

        do {
            return try await open(
                route: persistedRoute,
                adoption: adoption,
                identity: identity,
                store: store
            )
        } catch {
            let persistedRouteError = error
            let recoveredRoutes = await HarcMobileBonjourHostRouteResolver
                .discover()
            for route in recoveredRoutes where route != persistedRoute {
                do {
                    let recoveredRoute = try HarcMobileHostRoute(
                        host: route.host,
                        port: route.port,
                        serverHostname: route.serverHostname,
                        relay: persistedRoute.relay
                    )
                    let opened = try await open(
                        route: recoveredRoute,
                        adoption: adoption,
                        identity: identity,
                        store: store
                    )
                    do {
                        try HarcMobileHostRouteStore.save(
                            recoveredRoute,
                            to: routeURL
                        )
                        return opened
                    } catch {
                        await opened.connection.shutdownImmediately()
                    }
                } catch {}
            }
            if let relay = persistedRoute.relay {
                return try await openViaRelay(
                    route: persistedRoute,
                    relay: relay,
                    adoption: adoption,
                    identity: identity,
                    store: store
                )
            }
            throw persistedRouteError
        }
    }

    private static func openViaRelay(
        route: HarcMobileHostRoute,
        relay: HarcRemoteRelayRouteV1,
        adoption: ValidatedClientAdoptionEvidence,
        identity: InstallationSigningIdentity,
        store: HarcTransferStore
    ) async throws -> HarcMobileOpenedHostConnection {
        let tunnel = try await HarcRemoteRelayClientTunnel.open(route: relay)
        let trust = HarcTransportTrustCoordinator(
            adoptedPersistence:
                HarcTransferStoreTransportTrustPersistenceV1(store: store)
        )
        let connection: HarcPinnedGRPCConnection
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
        do {
            return try await finishOpening(
                connection: connection,
                adoption: adoption,
                identity: identity
            )
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private static func open(
        route: HarcMobileHostRoute,
        adoption: ValidatedClientAdoptionEvidence,
        identity: InstallationSigningIdentity,
        store: HarcTransferStore
    ) async throws -> HarcMobileOpenedHostConnection {
        let trust = HarcTransportTrustCoordinator(
            adoptedPersistence:
                HarcTransferStoreTransportTrustPersistenceV1(store: store)
        )
        let connection = try await HarcPinnedGRPCConnection.connect(
            host: route.host,
            port: Int(route.port),
            serverHostname: route.serverHostname,
            trustCoordinator: trust
        )
        do {
            return try await finishOpening(
                connection: connection,
                adoption: adoption,
                identity: identity
            )
        } catch {
            await connection.shutdownImmediately()
            throw error
        }
    }

    private static func finishOpening(
        connection: HarcPinnedGRPCConnection,
        adoption: ValidatedClientAdoptionEvidence,
        identity: InstallationSigningIdentity
    ) async throws -> HarcMobileOpenedHostConnection {
        let policy = try capabilityPolicy()
        let client = HarcBootstrapClient(
            rpc: connection,
            capabilityPolicy: policy,
            sasDictionary: try HarcSASDictionaryV1.bundled()
        )
        let negotiated = try await client.negotiateCapabilities(
            clientOffer: try capabilityOffer(policy: policy),
            expectation: HarcBootstrapTrustExpectation(adoption: adoption)
        )
        let session = try await client.openSession(
            adoption: adoption,
            negotiatedCapabilities: negotiated.negotiated,
            deviceSigner: identity
        )
        return HarcMobileOpenedHostConnection(
            connection: connection,
            adoption: adoption,
            session: session,
            negotiated: negotiated.negotiated,
            hostDisplayName: negotiated.hostInfo.displayName
        )
    }

    private static func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [.cafALAC]
        )
    }

    private static func capabilityOffer(
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

enum HarcMobileHostSessionConnectorError: Error {
    case notPaired
}
