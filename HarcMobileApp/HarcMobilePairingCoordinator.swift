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
        let id: UUID
        let client: HarcBootstrapClient
        let connection: HarcPinnedGRPCConnection
        let ticket: PairingTicketV1
        let route: HarcMobileHostRoute
        let presentation: HarcPairingClaimPresentation
    }

    private(set) var state: State

    private let identity: InstallationSigningIdentity
    private let store: HarcTransferStore
    private let routeURL: URL
    private let onAdopted: @MainActor () -> Void
    private var attempt: ActiveAttempt?
    /// Invalidates async continuations after rejection, reset, or forgetting.
    /// A late RPC can close its own connection but cannot adopt a Host after
    /// the user has ended that pairing attempt.
    private var operationGeneration: UInt64 = 0
    private var confirmingAttemptID: UUID?

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
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .connecting
        var connection: HarcPinnedGRPCConnection?
        var authenticatedPath: HarcVerifiedRoutePath?
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
                    return try await verifier.getHostInfo(
                        expectation: expectation
                    )
                },
                close: { candidate in
                    await candidate.shutdownImmediately()
                }
            )
            guard operationGeneration == generation else {
                await selected.connection.shutdownImmediately()
                return
            }
            let opened = selected.connection
            connection = opened
            authenticatedPath = selected.path
            let client = HarcBootstrapClient(
                rpc: opened,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            let presentation = try await client.beginPairing(
                ticket: ticket,
                deviceSigner: identity,
                requestedScopes: Self.requestedScopes(),
                deviceLabel: UIDevice.current.name,
                verifiedHostInfo: selected.verification
            )
            guard operationGeneration == generation else {
                await opened.shutdownImmediately()
                return
            }
            attempt = ActiveAttempt(
                id: UUID(),
                client: client,
                connection: opened,
                ticket: ticket,
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
            guard operationGeneration == generation else { return }
            if let routeFailure = error as? HarcVerifiedRouteFailure {
                let routes = routeFailure.triedEncryptedRelay
                    ? "the direct route or the encrypted relay"
                    : "the direct route"
                state = .failed(
                    "Harc could not authenticate the Host through \(routes). Keep the Host pairing screen open and create a fresh invitation. No device was adopted."
                )
            } else if let authenticatedPath {
                let route = authenticatedPath == .direct
                    ? "direct Host connection"
                    : "encrypted relay connection"
                let diagnostic = authenticatedPath == .direct
                    ? "PAIR-DIRECT-AFTER-VERIFY"
                    : "PAIR-RELAY-AFTER-VERIFY"
                state = .failed(
                    "Harc authenticated the Host, but the \(route) could not continue through claim creation. Keep both Harc apps open and create a fresh invitation. Diagnostic: \(diagnostic). No device was adopted."
                )
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func confirmWordsMatch() async {
        guard let attempt, confirmingAttemptID == nil else { return }
        let attemptID = attempt.id
        let generation = operationGeneration
        confirmingAttemptID = attemptID
        defer {
            if confirmingAttemptID == attemptID {
                confirmingAttemptID = nil
            }
        }
        var active = attempt
        var reconnectFailures = 0
        state = .awaitingHostApproval(
            host: attempt.presentation.hostDisplayName,
            phrase: attempt.presentation.sas.displayedPhrase
        )
        do {
            while true {
                try Task.checkCancellation()
                guard isCurrent(
                    attemptID: attemptID,
                    generation: generation
                ) else {
                    throw HarcMobilePairingError.ended("cancelled")
                }
                let now = UInt64(Date().timeIntervalSince1970 * 1_000)
                guard !active.presentation.isExpired(
                    atUnixMilliseconds: now
                )
                else { throw HarcMobilePairingError.ended("expired") }
                let result: HarcPairingClaimResult
                do {
                    result = try await active.client.getPairingStatus()
                    guard isCurrent(
                        attemptID: attemptID,
                        generation: generation
                    ) else {
                        await active.connection.shutdownImmediately()
                        return
                    }
                    reconnectFailures = 0
                } catch {
                    guard isCurrent(
                        attemptID: attemptID,
                        generation: generation
                    ) else {
                        await active.connection.shutdownImmediately()
                        return
                    }
                    let reconnectNow = UInt64(
                        Date().timeIntervalSince1970 * 1_000
                    )
                    guard !active.presentation.isExpired(
                        atUnixMilliseconds: reconnectNow
                    ) else { throw error }
                    do {
                        let reconnected = try await reconnect(active)
                        guard isCurrent(
                            attemptID: attemptID,
                            generation: generation
                        ) else {
                            await reconnected.connection.shutdownImmediately()
                            return
                        }
                        active = reconnected
                        self.attempt = reconnected
                        reconnectFailures = 0
                    } catch {
                        guard isCurrent(
                            attemptID: attemptID,
                            generation: generation
                        ) else { return }
                        reconnectFailures = min(reconnectFailures + 1, 4)
                        let delayMS = [500, 1_000, 2_000, 5_000][
                            reconnectFailures - 1
                        ]
                        try await Task.sleep(for: .milliseconds(delayMS))
                    }
                    continue
                }
                switch result {
                case .pending:
                    try await Task.sleep(for: .milliseconds(500))
                case .approved(let adoption, let remoteRelayRoute):
                    guard isCurrent(
                        attemptID: attemptID,
                        generation: generation
                    ) else {
                        await active.connection.shutdownImmediately()
                        return
                    }
                    let adoptedRoute = try HarcMobileHostRoute(
                        host: active.route.host,
                        port: active.route.port,
                        serverHostname: active.route.serverHostname,
                        relay: remoteRelayRoute
                    )
                    let priorRoute = try? HarcMobileHostRouteStore.load(
                        from: routeURL
                    )
                    try HarcMobileHostRouteStore.save(
                        adoptedRoute,
                        to: routeURL
                    )
                    do {
                        let activeAdoption = try store
                            .adoptApprovedForegroundPairing(adoption)
                        HarcMobileHostPresentationStore.saveDisplayName(
                            active.presentation.hostDisplayName,
                            hostAuthorityID:
                                activeAdoption.tuple.hostAuthorityID.description
                        )
                    } catch {
                        // Route evidence is useful only with the matching
                        // durable adoption. A rejected re-pair must not leave
                        // a new endpoint attached to the prior trust state.
                        if let priorRoute {
                            try? HarcMobileHostRouteStore.save(
                                priorRoute,
                                to: routeURL
                            )
                        } else {
                            try? HarcMobileHostRouteStore.removeIfPresent(
                                at: routeURL
                            )
                        }
                        throw error
                    }
                    self.attempt = nil
                    state = .paired(host: active.presentation.hostDisplayName)
                    onAdopted()
                    try await active.connection.shutdownGracefully()
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
            await active.connection.shutdownImmediately()
            guard isCurrent(
                attemptID: attemptID,
                generation: generation
            ) else { return }
            self.attempt = nil
            let message: String
            if let pairingError = error as? HarcMobilePairingError {
                message = pairingError.localizedDescription
            } else {
                message = "The pairing claim expired before Harc could reconnect and receive Host approval. Create a fresh invitation and try again."
            }
            state = .failed(message)
        }
    }

    /// Re-authenticates the original ticket route and transfers the proved
    /// claimant state to a fresh RPC client. Neither Bonjour nor the relay can
    /// alter the Host authority or security words already shown to the user.
    private func reconnect(_ attempt: ActiveAttempt) async throws
        -> ActiveAttempt
    {
        let trust = try HarcTransportTrustCoordinator(
            pairingExactQRTransportSet:
                attempt.ticket.exactTransportObjectBytes,
            hostAuthorityPublicKey: attempt.ticket.hostAuthorityPublicKey
        )
        let policy = try Self.capabilityPolicy()
        let expectation = try HarcBootstrapTrustExpectation(
            pairingTicket: attempt.ticket
        )
        let verify: @Sendable (HarcPinnedGRPCConnection) async throws
            -> HarcValidatedHostBootstrapInfo = { candidate in
            let verifier = HarcBootstrapClient(
                rpc: candidate,
                capabilityPolicy: policy,
                sasDictionary: try HarcSASDictionaryV1.bundled()
            )
            return try await verifier.getHostInfo(expectation: expectation)
        }

        let verified: HarcVerifiedRouteSelection<
            HarcPinnedGRPCConnection,
            HarcValidatedHostBootstrapInfo
        >
        let reconnectedRoute: HarcMobileHostRoute
        do {
            verified = try await openVerified(
                route: attempt.route,
                trust: trust,
                verify: verify
            )
            reconnectedRoute = attempt.route
        } catch let originalError {
            // A pairing ticket binds Host identity, not an IP address. DHCP,
            // Wi-Fi, or a dock may change while approval is pending, so every
            // Bonjour hint is authenticated against the exact original ticket.
            var repaired: HarcVerifiedRouteSelection<
                HarcPinnedGRPCConnection,
                HarcValidatedHostBootstrapInfo
            >?
            var repairedRoute: HarcMobileHostRoute?
            for candidate in await HarcMobileBonjourHostRouteResolver.discover()
            where candidate.host != attempt.route.host
                || candidate.port != attempt.route.port {
                let directCandidate = try HarcMobileHostRoute(
                    host: candidate.host,
                    port: candidate.port,
                    serverHostname: attempt.route.serverHostname
                )
                do {
                    repaired = try await openVerified(
                        route: directCandidate,
                        trust: trust,
                        verify: verify
                    )
                    repairedRoute = try HarcMobileHostRoute(
                        host: candidate.host,
                        port: candidate.port,
                        serverHostname: attempt.route.serverHostname,
                        relay: attempt.route.relay
                    )
                    break
                } catch {
                    continue
                }
            }
            guard let repaired, let repairedRoute else {
                throw originalError
            }
            verified = repaired
            reconnectedRoute = repairedRoute
        }

        do {
            let client = try await attempt.client.resumingPairing(
                on: verified.connection
            )
            await attempt.connection.shutdownImmediately()
            return ActiveAttempt(
                id: attempt.id,
                client: client,
                connection: verified.connection,
                ticket: attempt.ticket,
                route: reconnectedRoute,
                presentation: attempt.presentation
            )
        } catch {
            await verified.connection.shutdownImmediately()
            throw error
        }
    }

    private func openVerified(
        route: HarcMobileHostRoute,
        trust: HarcTransportTrustCoordinator,
        verify: @escaping @Sendable (HarcPinnedGRPCConnection) async throws
            -> HarcValidatedHostBootstrapInfo
    ) async throws -> HarcVerifiedRouteSelection<
        HarcPinnedGRPCConnection,
        HarcValidatedHostBootstrapInfo
    > {
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
        return try await HarcVerifiedRouteStrategy.openVerified(
            direct: {
                try await HarcPinnedGRPCConnection.connect(
                    host: route.host,
                    port: Int(route.port),
                    serverHostname: route.serverHostname,
                    trustCoordinator: trust
                )
            },
            relay: relayConnectionFactory,
            verify: verify,
            close: { connection in
                await connection.shutdownImmediately()
            }
        )
    }

    func wordsDoNotMatch() async {
        guard let attempt else {
            state = .unpaired
            return
        }
        operationGeneration &+= 1
        self.attempt = nil
        await attempt.client.abandonLocalPairingState()
        await attempt.connection.shutdownImmediately()
        state = .failed(
            "Security words did not match. The Host was not adopted. Create a new pairing code."
        )
    }

    func resetFailure() {
        guard case .failed = state else { return }
        operationGeneration &+= 1
        state = .unpaired
    }

    func scannerFailed(_ message: String) {
        guard attempt == nil else { return }
        state = .failed(message)
    }

    func beginReplacement() {
        guard attempt == nil else { return }
        // The existing adoption remains active until a new foreground pairing
        // succeeds. The scanner sheet owns this transient presentation, so a
        // cancellation cannot make a healthy pairing appear lost.
    }

    func pairingScannerCancelled() {
        guard attempt == nil else { return }
        restorePersistedPairingPresentation()
    }

    /// Local trust retirement never deletes protected captures or durable
    /// transfer state. Host-side revocation remains a separate authoritative
    /// action, as stated in the confirmation UI.
    func forgetActiveHost() {
        guard attempt == nil else { return }
        operationGeneration &+= 1
        do {
            _ = try store.forgetActiveHost()
            try HarcMobileHostRouteStore.removeIfPresent(at: routeURL)
            state = .unpaired
            onAdopted()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func restorePersistedPairingPresentation() {
        guard let adoption = try? store.activeAdoption() else {
            state = .unpaired
            return
        }
        let host = HarcMobileHostPresentationStore.displayName(
            hostAuthorityID: adoption.tuple.hostAuthorityID.description
        ) ?? "Harc Host"
        state = .paired(host: host)
    }

    private func isCurrent(
        attemptID: UUID,
        generation: UInt64
    ) -> Bool {
        operationGeneration == generation && attempt?.id == attemptID
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
