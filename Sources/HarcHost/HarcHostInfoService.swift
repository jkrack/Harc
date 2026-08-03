import Foundation
import HarcIdentity

/// Public bootstrap application service. It exposes only the canonical host
/// identity tuple, capability facts, exact current signed transport set, and
/// host time. Device, ticket, session, and library state never enter this API.
public actor HarcHostInfoService {
    public static let maximumRequestsPerSource = 60
    public static let requestWindow: TimeInterval = 60

    private static let maximumTrackedSources = 4_096
    private static let maximumDisplayNameBytes = 256
    private static let maximumExactlyRepresentableUnixMilliseconds: Double =
        9_007_199_254_740_991

    private let store: HarcHostStore
    private let displayName: String
    private let hostAuthorityPublicKey: P256X963PublicKey
    private let protocolBoundary: any HostInfoProtocolBoundary
    private var attemptsBySource: [HostPreauthenticationSource: [TimeInterval]] = [:]
    private var admissionsSinceSweep = 0

    public init(
        store: HarcHostStore,
        displayName: String,
        hostAuthorityPublicKey: P256X963PublicKey,
        protocolBoundary: any HostInfoProtocolBoundary
    ) throws {
        guard hostAuthorityPublicKey.hostAuthorityID
                == store.expectedMetadata.hostAuthorityID else {
            throw HarcHostError.metadataMismatch
        }
        try Self.validateDisplayName(displayName)
        self.store = store
        self.displayName = displayName
        self.hostAuthorityPublicKey = hostAuthorityPublicKey
        self.protocolBoundary = protocolBoundary
    }

    public func getHostInfo(
        _ request: GetHostInfoRequest
    ) async throws -> GetHostInfoResponse {
        let serverTime = try admitPublicRequest(from: request.source)
        try protocolBoundary.validateProtocolVersion(
            major: request.protocolMajor,
            minor: request.protocolMinor
        )
        let offers = try protocolBoundary.advertisedCapabilityOffers()
        guard !offers.isEmpty,
              offers.contains(where: {
                  $0.supports(
                      protocolMajor: request.protocolMajor,
                      protocolMinor: request.protocolMinor
                  )
              }) else {
            throw HarcHostError.invalidHostInfoInput("advertised capability offers")
        }
        let exactTransportSet = try await currentExactSignedTransportSet()

        return GetHostInfoResponse(
            protocolMajor: request.protocolMajor,
            protocolMinor: request.protocolMinor,
            displayName: displayName,
            libraryID: store.expectedMetadata.libraryID,
            hostAuthorityID: store.expectedMetadata.hostAuthorityID,
            hostAuthorityPublicKey: hostAuthorityPublicKey,
            offers: offers,
            exactSignedTransportSet: exactTransportSet,
            serverTime: serverTime
        )
    }

    public func negotiateCapabilities(
        _ request: NegotiateHostCapabilitiesRequest
    ) async throws -> NegotiateHostCapabilitiesResponse {
        let serverTime = try admitPublicRequest(from: request.source)
        try protocolBoundary.validateProtocolVersion(
            major: request.protocolMajor,
            minor: request.protocolMinor
        )
        let negotiated = try protocolBoundary.negotiateCapabilities(
            protocolMajor: request.protocolMajor,
            protocolMinor: request.protocolMinor,
            clientOffer: request.clientOffer
        )
        guard negotiated.protocolMajor == request.protocolMajor,
              negotiated.protocolMinor == request.protocolMinor else {
            throw HarcHostError.invalidHostInfoInput(
                "negotiated capability protocol"
            )
        }
        let exactTransportSet = try await currentExactSignedTransportSet()

        return NegotiateHostCapabilitiesResponse(
            protocolMajor: negotiated.protocolMajor,
            protocolMinor: negotiated.protocolMinor,
            exactNegotiatedCapabilities: negotiated.exactBytes,
            negotiatedCapabilitiesSHA256: negotiated.sha256,
            exactSignedTransportSet: exactTransportSet,
            serverTime: serverTime
        )
    }

    private func currentExactSignedTransportSet() async throws -> Data {
        try await store.requireServingBootstrapActive()
        let snapshot = try await store.transportDatabaseSnapshot()
        guard snapshot.pending == nil else {
            throw HarcHostError.transportSetTransitionInProgress
        }
        guard snapshot.epoch > 0,
              let exact = snapshot.exactSignedBytes,
              (1 ... HostValidatedTransportSet.maximumExactSignedBytes)
                .contains(exact.count),
              snapshot.objectID?.count == 32 else {
            throw HarcHostError.transportSetNotInitialized
        }
        return exact
    }

    private func admitPublicRequest(
        from source: HostPreauthenticationSource
    ) throws -> Date {
        let observedTime = store.now()
        let observedMilliseconds = observedTime.timeIntervalSince1970 * 1_000
        guard observedMilliseconds.isFinite,
              observedMilliseconds >= 0,
              observedMilliseconds
                <= Self.maximumExactlyRepresentableUnixMilliseconds else {
            throw HarcHostError.invalidHostInfoInput("server time")
        }
        let exactMilliseconds = observedMilliseconds.rounded(.down)
        let serverTime = Date(
            timeIntervalSince1970: exactMilliseconds / 1_000
        )
        let timestamp = serverTime.timeIntervalSince1970
        let windowStart = timestamp - Self.requestWindow
        admissionsSinceSweep += 1
        if admissionsSinceSweep >= 64 {
            attemptsBySource = attemptsBySource.filter { _, attempts in
                attempts.contains(where: { $0 > windowStart })
            }
            admissionsSinceSweep = 0
        }

        var attempts = attemptsBySource[source, default: []]
            .filter { $0 > windowStart }
        guard attempts.count < Self.maximumRequestsPerSource else {
            attemptsBySource[source] = attempts
            throw HarcHostError.publicHostInfoRateLimited
        }
        if attemptsBySource[source] == nil,
           attemptsBySource.count >= Self.maximumTrackedSources {
            throw HarcHostError.publicHostInfoRateLimited
        }
        attempts.append(timestamp)
        attemptsBySource[source] = attempts
        return serverTime
    }

    private static func validateDisplayName(_ value: String) throws {
        guard value == value.precomposedStringWithCanonicalMapping,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximumDisplayNameBytes,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw HarcHostError.invalidHostInfoInput("display name")
        }
    }
}
