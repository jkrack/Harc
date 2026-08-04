import Foundation
import HarcClientStore
import HarcClientTransport
import HarcIdentity
import HarcProtocol
import HarcTransfer

struct HarcMobileOpenedHostConnection: Sendable {
    let connection: HarcPinnedGRPCConnection
    let adoption: ValidatedClientAdoptionEvidence
    let session: HarcOpenedClientSession
    let negotiated: HarcValidatedNegotiatedCapabilitiesV1
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
                    let opened = try await open(
                        route: route,
                        adoption: adoption,
                        identity: identity,
                        store: store
                    )
                    do {
                        try HarcMobileHostRouteStore.save(route, to: routeURL)
                        return opened
                    } catch {
                        await opened.connection.shutdownImmediately()
                    }
                } catch {}
            }
            throw persistedRouteError
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
            return HarcMobileOpenedHostConnection(
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
