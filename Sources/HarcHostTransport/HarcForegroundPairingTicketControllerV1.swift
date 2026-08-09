#if canImport(Network)
import Foundation
import HarcRemoteTransport
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol
import Network

/// Memory-only foreground payload rendered by the Host UI as a QR code.
/// The URI contains the ticket secret and must never be logged or persisted
/// automatically. The foreground UI may explicitly export a short-lived copy
/// at the user's direction for pairing a remote Mac.
public struct HarcForegroundPairingTicketV1: Equatable, Sendable {
    public let ticketID: UUID
    public let clientKind: AdoptedClientKind
    public let pairingURI: String
    public let issuedAt: Date
    public let expiresAt: Date
    public let hostAuthorityID: HostAuthorityID

    public init(
        ticketID: UUID,
        clientKind: AdoptedClientKind,
        pairingURI: String,
        issuedAt: Date,
        expiresAt: Date,
        hostAuthorityID: HostAuthorityID
    ) {
        self.ticketID = ticketID
        self.clientKind = clientKind
        self.pairingURI = pairingURI
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.hostAuthorityID = hostAuthorityID
    }
}

public enum HarcForegroundPairingTicketControllerError:
    Error, Equatable, Sendable
{
    case invalidClock
    case invalidTicketIdentifier
    case transportIdentityMismatch
}

/// One foreground pairing window owns this actor. Issuing a replacement first
/// cancels the prior durable placeholder, and dismissal cancels the active one.
/// Raw ticket secrets exist only in the returned in-memory URI unless the user
/// explicitly exports the same short-lived payload from the foreground UI.
public actor HarcForegroundPairingTicketControllerV1 {
    public static let ticketLifetime: TimeInterval = 120

    private let hostStore: HarcHostStore
    private let tuple: HostCryptographicStateTuple
    private let authorityPublicKey: P256X963PublicKey
    private let transportReservation: any HarcCapabilityTransportReserving
    private let endpoints: [PairingEndpointV1]
    private let randomness: any HostAuthenticationRandomness
    private let now: @Sendable () -> Date
    private let remoteRelayHostAgent: HarcRemoteRelayHostAgent?
    private let remoteRelayRouteDeliveryBox:
        HarcRemoteRelayRouteDeliveryBox?
    private var activeTicketID: UUID?
    private var activeRelayRouteID: String?

    package init(
        storageRuntime: HarcResidentHostStorageRuntime,
        transportRuntime: HostTransportResidentRuntime,
        endpoints: [PairingEndpointV1],
        remoteRelayHostAgent: HarcRemoteRelayHostAgent? = nil,
        remoteRelayRouteDeliveryBox:
            HarcRemoteRelayRouteDeliveryBox? = nil
    ) {
        self.init(
            hostStore: storageRuntime.hostStore,
            tuple: storageRuntime.tuple,
            authorityPublicKey: storageRuntime.authorityPublicKey,
            transportReservation: transportRuntime,
            endpoints: endpoints,
            randomness: SystemHostAuthenticationRandomness(),
            now: Date.init,
            remoteRelayHostAgent: remoteRelayHostAgent,
            remoteRelayRouteDeliveryBox: remoteRelayRouteDeliveryBox
        )
    }

    init(
        hostStore: HarcHostStore,
        tuple: HostCryptographicStateTuple,
        authorityPublicKey: P256X963PublicKey,
        transportReservation: any HarcCapabilityTransportReserving,
        endpoints: [PairingEndpointV1],
        randomness: any HostAuthenticationRandomness =
            SystemHostAuthenticationRandomness(),
        now: @escaping @Sendable () -> Date = Date.init,
        remoteRelayHostAgent: HarcRemoteRelayHostAgent? = nil,
        remoteRelayRouteDeliveryBox:
            HarcRemoteRelayRouteDeliveryBox? = nil
    ) {
        self.hostStore = hostStore
        self.tuple = tuple
        self.authorityPublicKey = authorityPublicKey
        self.transportReservation = transportReservation
        self.endpoints = endpoints
        self.randomness = randomness
        self.now = now
        self.remoteRelayHostAgent = remoteRelayHostAgent
        self.remoteRelayRouteDeliveryBox = remoteRelayRouteDeliveryBox
    }

    public func issue(
        for clientKind: AdoptedClientKind
    ) async throws -> HarcForegroundPairingTicketV1 {
        try await cancelActiveTicketIfNeeded()

        let observedAt = now()
        let observedMilliseconds = observedAt.timeIntervalSince1970 * 1_000
        guard observedMilliseconds.isFinite,
              observedMilliseconds >= 0,
              observedMilliseconds <= Double(UInt64.max - 120_000) else {
            throw HarcForegroundPairingTicketControllerError.invalidClock
        }
        let issuedMilliseconds = UInt64(observedMilliseconds.rounded(.down))
        let expiresMilliseconds = issuedMilliseconds + 120_000
        let issuedAt = Date(
            timeIntervalSince1970: Double(issuedMilliseconds) / 1_000
        )
        let expiresAt = Date(
            timeIntervalSince1970: Double(expiresMilliseconds) / 1_000
        )
        let reservation = try await transportReservation
            .reserveTransportForBackgroundCapability(expiringAt: expiresAt)
        let verifiedTransport = try VerifiedHostTransportSetV1.decode(
            reservation.exactSignedTransportSet,
            hostAuthorityPublicKey: authorityPublicKey
        )
        guard verifiedTransport.transportSet.libraryID == tuple.libraryID,
              verifiedTransport.transportSet.hostAuthorityID
                == tuple.hostAuthorityID,
              verifiedTransport.transportSet.setEpoch
                == reservation.minimumTransportSetEpoch,
              authorityPublicKey.hostAuthorityID == tuple.hostAuthorityID else {
            throw HarcForegroundPairingTicketControllerError
                .transportIdentityMismatch
        }

        let ticketID = try randomness.randomUUID()
        guard ticketID != Self.zeroUUID else {
            throw HarcForegroundPairingTicketControllerError
                .invalidTicketIdentifier
        }
        let secret = try randomness.randomBytes(count: 24)
        var ticketEndpoints = endpoints
        var issuedRelayRouteID: String?
        if let remoteRelayHostAgent {
            let relay = try await remoteRelayHostAgent.issueAdmission(
                kind: .pairing,
                expiresAtMilliseconds: expiresMilliseconds
            )
            guard let serviceHost = relay.serviceOrigin.host else {
                throw HarcRemoteRelayError.invalidServiceOrigin
            }
            ticketEndpoints.append(
                try PairingRelayEndpointV1(
                    serviceHost: serviceHost,
                    hostRouteID: relay.hostRouteID,
                    admissionRouteID: relay.deviceRouteID,
                    capability: relay.capability
                ).pairingEndpoint()
            )
            issuedRelayRouteID = relay.deviceRouteID
        }
        let ticket = try PairingTicketV1(
            ticketID: ticketID,
            libraryID: tuple.libraryID,
            hostAuthorityID: tuple.hostAuthorityID,
            hostAuthorityPublicKey: authorityPublicKey,
            verifiedTransportSet: verifiedTransport,
            ticketSecret: secret,
            issuedAtUnixMilliseconds: issuedMilliseconds,
            expiresAtUnixMilliseconds: expiresMilliseconds,
            endpoints: ticketEndpoints
        )
        let placeholder = try PairingTicketPlaceholder(
            ticketID: ticketID,
            ticketSecretBindingSHA256: ticket.ticketSecretBindingSHA256,
            clientKind: clientKind,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let pairingURI = try ticket.encodedURI()
        try await hostStore.insertPairingTicketPlaceholder(placeholder)
        activeTicketID = ticketID
        activeRelayRouteID = issuedRelayRouteID
        return HarcForegroundPairingTicketV1(
            ticketID: ticketID,
            clientKind: clientKind,
            pairingURI: pairingURI,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            hostAuthorityID: tuple.hostAuthorityID
        )
    }

    public func cancel() async throws {
        try await cancelActiveTicketIfNeeded()
    }

    /// Replaces the one-time invitation admission with a freshly randomized,
    /// reusable transport-only route. The invitation bearer is never promoted.
    public func provisionApprovedRelayRoute(
        forTicketID ticketID: UUID,
        claimID: UUID,
        deviceID: DeviceID
    ) async throws {
        guard activeTicketID == ticketID,
              let invitationRouteID = activeRelayRouteID,
              let remoteRelayHostAgent,
              let remoteRelayRouteDeliveryBox else { return }
        let observed = now().timeIntervalSince1970 * 1_000
        guard observed.isFinite, observed >= 0,
              observed <= Double(UInt64.max) else {
            throw HarcForegroundPairingTicketControllerError.invalidClock
        }
        let approvedAt = UInt64(observed.rounded(.down))
        let expiresAt = approvedAt
            + 366 * 24 * 60 * 60 * 1_000
        let route = try await remoteRelayHostAgent.issueAdmission(
            kind: .device,
            expiresAtMilliseconds: expiresAt
        )
        do {
            try await remoteRelayRouteDeliveryBox.saveBinding(
                route,
                forDeviceID: deviceID,
                expiresAtMilliseconds: expiresAt
            )
            try await remoteRelayRouteDeliveryBox.save(
                route,
                forClaimID: claimID,
                expiresAtMilliseconds: approvedAt + 10 * 60 * 1_000
            )
        } catch {
            try? await remoteRelayRouteDeliveryBox.removeBinding(
                forDeviceID: deviceID
            )
            try? await remoteRelayHostAgent.revoke(
                routeID: route.deviceRouteID
            )
            throw error
        }
        try await remoteRelayHostAgent.revoke(routeID: invitationRouteID)
        activeRelayRouteID = nil
    }

    private func cancelActiveTicketIfNeeded() async throws {
        guard let ticketID = activeTicketID else { return }
        let relayRouteID = activeRelayRouteID
        activeTicketID = nil
        activeRelayRouteID = nil
        do {
            try await hostStore.cancelPairingTicketIfOpen(ticketID: ticketID)
            if let relayRouteID {
                try? await remoteRelayHostAgent?.revoke(
                    routeID: relayRouteID
                )
            }
        } catch {
            // Restore ownership so a transient HostDB failure cannot silently
            // orphan a still-live secret-bearing foreground presentation.
            activeTicketID = ticketID
            activeRelayRouteID = relayRouteID
            throw error
        }
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}
#endif
