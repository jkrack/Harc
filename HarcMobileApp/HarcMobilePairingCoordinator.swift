import Foundation
import HarcAudioMobile
import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Observation
import UIKit

@MainActor
@Observable
final class HarcMobilePairingCoordinator {
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
        state = hasActiveAdoption ? .paired(host: "Adopted Host") : .unpaired
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
            let opened = try await HarcPinnedGRPCConnection.connect(
                host: route.host,
                port: Int(route.port),
                serverHostname: route.serverHostname,
                trustCoordinator: trust
            )
            connection = opened
            let client = HarcBootstrapClient(
                rpc: opened,
                capabilityPolicy: try Self.capabilityPolicy(),
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
            state = .failed(error.localizedDescription)
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
                case .approved(let adoption):
                    try HarcMobileHostRouteStore.save(attempt.route, to: routeURL)
                    _ = try store.adopt(adoption)
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
