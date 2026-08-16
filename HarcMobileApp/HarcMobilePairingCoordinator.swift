import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcRemoteTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Observation
import UIKit

@MainActor
@Observable
final class HarcMobilePairingCoordinator {
    private typealias ConnectionFactory =
        @Sendable () async throws -> HarcPinnedGRPCConnection

    enum State: Equatable {
        case unpaired
        case connecting
        case compareWords(host: String, phrase: String, expiresAt: Date)
        case awaitingHostApproval(host: String, phrase: String)
        case paired(host: String)
        case failed(String)
    }

    private struct ActiveAttempt {
        let client: HarcBootstrapClient
        let connection: HarcPinnedGRPCConnection
        let route: HarcMobileHostRoute
        let presentation: HarcPairingClaimPresentation
    }

    private(set) var state: State

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let routeURL: URL
    private let onAdopted: @MainActor () -> Void
    private var attempt: ActiveAttempt?

    init(
        identity: InstallationSigningIdentity,
        store: HarcTransferStore,
        routeURL: URL,
        hasActiveAdoption: Bool,
        onAdopted: @escaping @MainActor () -> Void = {}
    ) {
        self.identity = identity
        self.store = store
        self.routeURL = routeURL
        self.onAdopted = onAdopted
        let activeAdoption = try? store.activeAdoption()
        let storedHostName = activeAdoption.flatMap {
            HarcMobileHostPresentationStore.displayName(
                hostAuthorityID: $0.tuple.hostAuthorityID.description
            )
        }
        state = hasActiveAdoption
            ? .paired(host: storedHostName ?? "Harc Host")
            : .unpaired
    }

    var pairedHostDisplayName: String? {
        guard case .paired(let host) = state else { return nil }
        return host
    }

    func begin(scannedURI: String) async {
        guard attempt == nil else { return }
        state = .connecting
        var connection: HarcPinnedGRPCConnection?
        do {
            let nowMS = UInt64(Date().timeIntervalSince1970 * 1_000)
            let ticket = try PairingTicketV1.decodeURI(
                scannedURI,
                atUnixMilliseconds: nowMS
            )
            let route = try HarcMobileHostRoute(ticket: ticket)
            let trust = try HarcTransportTrustCoordinator(
                pairingExactQRTransportSet: ticket.exactTransportObjectBytes,
                hostAuthorityPublicKey: ticket.hostAuthorityPublicKey
            )
            let policy = try Self.capabilityPolicy()
            let expectation = try HarcBootstrapTrustExpectation(
                pairingTicket: ticket
            )
            let relayConnectionFactory: ConnectionFactory?
            if let relay = route.relay {
                relayConnectionFactory = {
                    let tunnel = try await HarcRemoteRelayClientTunnel.open(
                        route: relay
                    )
                    do {
                        return try await HarcPinnedGRPCConnection.connect(
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
            } else {
                relayConnectionFactory = nil
            }
            let selected = try await HarcVerifiedRouteStrategy.openVerified(
                direct: {
                    try await HarcPinnedGRPCConnection.connect(
                        host: route.host,
                        port: Int(route.port),
                        serverHostname: route.serverHostname,
                        trustCoordinator: trust
                    )
                },
                relay: relayConnectionFactory,
                verify: { candidate in
                    let verifier = HarcBootstrapClient(
                        rpc: candidate,
                        capabilityPolicy: policy,
                        sasDictionary: try HarcSASDictionaryV1.bundled()
                    )
                    _ = try await verifier.getHostInfo(
                        expectation: expectation
                    )
                },
                close: { candidate in
                    await candidate.shutdownImmediately()
                }
            )
            let opened = selected.connection
            connection = opened
            let client = HarcBootstrapClient(
                rpc: opened,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let presentation = try await client.beginPairing(
                ticket: ticket,
                deviceSigner: identity,
                requestedScopes: Self.requestedScopes(),
                deviceLabel: UIDevice.current.name
            )
            attempt = ActiveAttempt(
                client: client,
                connection: opened,
                route: route,
                presentation: presentation
            )
            state = .compareWords(
                host: presentation.hostDisplayName,
                phrase: presentation.sas.displayedPhrase,
                expiresAt: Date(
                    timeIntervalSince1970:
                        Double(presentation.expiresAtUnixMilliseconds) / 1_000
                )
            )
        } catch {
            if let connection { await connection.shutdownImmediately() }
            if let routeFailure = error as? HarcVerifiedRouteFailure {
                let routes = routeFailure.triedEncryptedRelay
                    ? "the direct route or the encrypted relay"
                    : "the direct route"
                state = .failed(
                    "Harc could not authenticate the Host through \(routes). Keep the Host pairing screen open and create a fresh invitation. No device was adopted."
                )
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func confirmWordsMatch() async {
        guard let attempt else { return }
        state = .awaitingHostApproval(
            host: attempt.presentation.hostDisplayName,
            phrase: attempt.presentation.sas.displayedPhrase
        )
        do {
            while true {
                try Task.checkCancellation()
                switch try await attempt.client.getPairingStatus() {
                case .pending:
                    try await Task.sleep(for: .milliseconds(500))
                case .approved(let adoption, let remoteRelayRoute):
                    let adoptedRoute = try HarcMobileHostRoute(
                        host: attempt.route.host,
                        port: attempt.route.port,
                        serverHostname: attempt.route.serverHostname,
                        relay: remoteRelayRoute
                    )
                    try HarcMobileHostRouteStore.save(
                        adoptedRoute,
                        to: routeURL
                    )
                    let activeAdoption = try store.adopt(adoption)
                    HarcMobileHostPresentationStore.saveDisplayName(
                        attempt.presentation.hostDisplayName,
                        hostAuthorityID:
                            activeAdoption.tuple.hostAuthorityID.description
                    )
                    try await attempt.connection.shutdownGracefully()
                    self.attempt = nil
                    state = .paired(host: attempt.presentation.hostDisplayName)
                    onAdopted()
                    return
                case .denied:
                    throw HarcMobilePairingError.ended("denied")
                case .expired:
                    throw HarcMobilePairingError.ended("expired")
                case .cancelled:
                    throw HarcMobilePairingError.ended("cancelled")
                }
            }
        } catch {
            await attempt.connection.shutdownImmediately()
            self.attempt = nil
            state = .failed(error.localizedDescription)
        }
    }

    func wordsDoNotMatch() async {
        guard let attempt else {
            state = .unpaired
            return
        }
        await attempt.client.abandonLocalPairingState()
        await attempt.connection.shutdownImmediately()
        self.attempt = nil
        state = .failed(
            "Security words did not match. The Host was not adopted. Create a new pairing code."
        )
    }

    func resetFailure() {
        guard case .failed = state else { return }
        state = .unpaired
    }

    func scannerFailed(_ message: String) {
        guard attempt == nil else { return }
        state = .failed(message)
    }

    func beginReplacement() {
        guard attempt == nil else { return }
        state = .unpaired
    }

    private static func capabilityPolicy() throws -> HarcCapabilityPolicyV1 {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [ChunkDescriptorSchema.v1.rawValue],
            supportedEncodings: [.cafALAC]
        )
    }

    /// The mobile beta includes the canonical Library experience, so pairing
    /// requests its read/playback/mutation scopes explicitly. The Host still
    /// presents and locally authenticates this expansion; requested scopes are
    /// never self-granted by the phone.
    private static func requestedScopes() -> [AuthorizationScope] {
        var scopes = ScopePolicy.minimalScopes(for: .mobile)
        scopes.append(contentsOf: [
            .libraryMetadataRead,
            .libraryTranscriptRead,
            .libraryAudioRead,
            .libraryMetadataWrite,
            .speakerIdentityRead,
            .speakerObservationWrite,
            .speakerAssignmentWrite,
        ])
        return Array(Set(scopes)).sorted()
    }
}

private enum HarcMobilePairingError: LocalizedError {
    case ended(String)

    var errorDescription: String? {
        switch self {
        case .ended(let state):
            "Pairing ended without approval: \(state)."
        }
    }
}
