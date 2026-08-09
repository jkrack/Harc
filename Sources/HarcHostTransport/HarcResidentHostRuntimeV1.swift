#if canImport(Network)
import Foundation
import HarcRemoteTransport
import HarcDomain
import HarcHost
import HarcIdentity
import HarcProtocol
import HarcTransfer
import Network

/// App-owned configuration for one resident Harc V1 Host.
public struct HarcResidentHostRuntimeConfigurationV1: Sendable {
    public let storage: HarcResidentHostStorageConfiguration
    public let canonicalAudioRoot: URL
    public let backgroundRollbackRoot: URL
    public let temporaryUploadParent: URL
    public let displayName: String
    public let localDNSTarget: String
    public let discoveryCapabilityBits: UInt64
    public let acceptedEdgeEngineRevisions: Set<String>
    public let remoteRelay: HarcRemoteRelayHostConfigurationV1?
    public let remoteRelayRouteDeliveryPersistence:
        (any HarcRemoteRelayRouteDeliveryPersistence)?

    public init(
        storage: HarcResidentHostStorageConfiguration,
        canonicalAudioRoot: URL,
        backgroundRollbackRoot: URL,
        temporaryUploadParent: URL = FileManager.default.temporaryDirectory,
        displayName: String,
        localDNSTarget: String,
        discoveryCapabilityBits: UInt64 = 0,
        acceptedEdgeEngineRevisions: Set<String> = [],
        remoteRelay: HarcRemoteRelayHostConfigurationV1? = nil,
        remoteRelayRouteDeliveryPersistence:
            (any HarcRemoteRelayRouteDeliveryPersistence)? = nil
    ) {
        self.storage = storage
        self.canonicalAudioRoot = canonicalAudioRoot
        self.backgroundRollbackRoot = backgroundRollbackRoot
        self.temporaryUploadParent = temporaryUploadParent
        self.displayName = displayName
        self.localDNSTarget = localDNSTarget
        self.discoveryCapabilityBits = discoveryCapabilityBits
        self.acceptedEdgeEngineRevisions = acceptedEdgeEngineRevisions
        self.remoteRelay = remoteRelay
        self.remoteRelayRouteDeliveryPersistence =
            remoteRelayRouteDeliveryPersistence
    }
}

/// Public, app-facing lifecycle for the complete resident Host transport.
///
/// This actor owns the one canonical writer, HostDB, recovery service, both
/// TLS listeners, Bonjour advertisement, pairing window, and local approval
/// controller. Lower-level listener and authority objects remain package-only.
public actor HarcResidentHostRuntimeV1 {
    public nonisolated let storageRuntime: HarcResidentHostStorageRuntime
    public nonisolated let tuple: HostCryptographicStateTuple
    public nonisolated let listenerPorts: HarcHostListenerPorts
    public nonisolated let startupRecoveryReport: HostCanonicalRecoveryReport

    private let transportRuntime: HostTransportResidentRuntime
    private let canonicalIngest: HarcCanonicalIngestService
    private let pairingTickets: HarcForegroundPairingTicketControllerV1
    private let pairingApproval: HarcLocalPairingApprovalService
    private let remoteRelayHostAgent: HarcRemoteRelayHostAgent?
    private let remoteRelayRouteDeliveryBox:
        HarcRemoteRelayRouteDeliveryBox
    private var transportStopped = false
    private var hostModeDisabled = false

    /// Builds the entire production Host graph and returns only after the
    /// transport generation has bound both persisted ports and registered its
    /// Bonjour advertisement. The processing scheduler is mandatory because a
    /// durable receipt must never claim a successful handoff to a missing
    /// processing pipeline.
    public static func start(
        configuration: HarcResidentHostRuntimeConfigurationV1,
        processingScheduler: any HostReceiptDurableProcessingScheduling,
        cryptographicStateStore: any HostCryptographicStateStore =
            KeychainHostCryptographicStateStore()
    ) async throws -> HarcResidentHostRuntimeV1 {
        try await start(
            configuration: configuration,
            cryptographicStateStore: cryptographicStateStore,
            makeProcessingScheduler: { _ in processingScheduler }
        )
    }

    /// App-composition entry point used when the scheduler must share the
    /// exact RecordingStore owned by the resident Host runtime.
    public static func start(
        configuration: HarcResidentHostRuntimeConfigurationV1,
        cryptographicStateStore: any HostCryptographicStateStore =
            KeychainHostCryptographicStateStore(),
        makeProcessingScheduler: @Sendable (
            HarcResidentHostStorageRuntime
        ) async throws -> any HostReceiptDurableProcessingScheduling
    ) async throws -> HarcResidentHostRuntimeV1 {
        let storage = try await HarcResidentHostStorageRuntime.start(
            configuration: configuration.storage,
            cryptographicStateStore: cryptographicStateStore
        )
        var startedTransport: HostTransportResidentRuntime?

        do {
            let processingScheduler = try await makeProcessingScheduler(storage)
            let state = try await cryptographicStateStore.load(
                requiredTuple: storage.tuple
            )
            guard state.tuple == storage.tuple,
                  state.authorityIdentity.publicKey
                    == storage.authorityPublicKey else {
                throw HarcHostError.metadataMismatch
            }

            let capabilityPolicy = try productionCapabilityPolicy()
            let offer = productionCapabilityOffer()
            let infoProtocol = try HarcHostInfoProtocolAdapterV1(
                capabilityPolicy: capabilityPolicy,
                hostOffer: offer
            )
            let authenticationProtocol = try
                HarcHostAuthenticationProtocolAdapterV1(
                    capabilityPolicy: capabilityPolicy
                )
            let hostInfo = try HarcHostInfoService(
                store: storage.hostStore,
                displayName: configuration.displayName,
                hostAuthorityPublicKey: storage.authorityPublicKey,
                protocolBoundary: infoProtocol
            )
            let pairing = try HarcPairingClaimService(
                store: storage.hostStore,
                protocolBoundary: authenticationProtocol
            )
            let session = HarcSessionService(
                store: storage.hostStore,
                protocolBoundary: authenticationProtocol
            )
            let approval = HarcLocalPairingApprovalService(
                store: storage.hostStore,
                issuer: HarcHostPairingGrantIssuerV1(
                    cryptographicStateStore: cryptographicStateStore,
                    expectedTuple: storage.tuple
                )
            )

            let evidence = HarcRecordingEvidenceCodecV1()
            let ingest = try HarcCanonicalIngestService(
                hostStore: storage.hostStore,
                recordingStore: storage.recordingStore,
                canonicalCommitCapability:
                    storage.writerLease.canonicalCommitCapability,
                canonicalRoot: configuration.canonicalAudioRoot,
                decoder: CAFALACHostChunkDecoder(),
                manifestValidator: evidence,
                receiptIssuer: evidence,
                receiptValidator: evidence,
                hostAuthoritySigner: state.authorityIdentity,
                processingScheduler: processingScheduler
            )
            let backgroundTransportRelay =
                HarcDeferredBackgroundCapabilityTransportProviderRelay()
            let recording = HostRecordingTransferService(
                hostStore: storage.hostStore,
                canonicalIngest: ingest,
                backgroundCapabilityTransportSnapshotProvider:
                    backgroundTransportRelay
            )
            let library = HarcHostLibraryService(
                store: storage.recordingStore,
                hostStore: storage.hostStore
            )
            let processing = HarcHostProcessingArtifactService(
                hostStore: storage.hostStore,
                recordingStore: storage.recordingStore,
                sessionService: session,
                acceptedEngineRevisions:
                    configuration.acceptedEdgeEngineRevisions,
                compatibility: capabilityPolicy.compatibility
            )
            let sourceSecret = try SystemHostAuthenticationRandomness()
                .randomBytes(count: 32)
            let remoteRelayRouteDeliveryBox =
                HarcRemoteRelayRouteDeliveryBox(
                    persistence:
                        configuration.remoteRelayRouteDeliveryPersistence
                )
            let bootstrapFactory = try HarcBootstrapGRPCServiceFactoryV1(
                hostInfoService: hostInfo,
                pairingService: pairing,
                sessionService: session,
                recordingService: recording,
                libraryService: library,
                processingService: processing,
                hostAuthorityPublicKey: storage.authorityPublicKey,
                capabilityPolicy: capabilityPolicy,
                hostScopedSourceSecret: sourceSecret,
                remoteRelayRouteDeliveryBox:
                    remoteRelayRouteDeliveryBox
            )
            let grpcRuntime = HarcGRPCServerRuntime(
                bootstrapServiceFactory: bootstrapFactory
            )

            let trust = try RecordingHostTrustBinding(
                libraryID: storage.tuple.libraryID,
                hostAuthorityID: storage.tuple.hostAuthorityID,
                hostAuthorityPublicKey: storage.authorityPublicKey
            )
            let backgroundIngest = try HarcBackgroundBatchIngestApplicationV1(
                hostStore: storage.hostStore,
                rollbackRoot: configuration.backgroundRollbackRoot,
                hostTrust: trust,
                hostAuthoritySigner: state.authorityIdentity,
                supportedRequiredFeatures:
                    capabilityPolicy.compatibility.supportedRequiredFeatures
            )
            let uploadRuntime = try HarcBackgroundUploadListenerRuntimeV1(
                application: backgroundIngest,
                temporaryParentDirectory: configuration.temporaryUploadParent
            )
            let generationDriver = HarcResidentTransportGenerationDriver(
                grpcRuntime: grpcRuntime,
                uploadRuntime: uploadRuntime
            )
            let hints = try HarcBonjourServiceHintsV1(
                displayName: configuration.displayName,
                protocolMajor: 1,
                protocolMinor: 0,
                capabilityBits: configuration.discoveryCapabilityBits,
                uploadPortHint: storage.listenerPorts.uploadPort
            )
            guard let controlPort = NWEndpoint.Port(
                rawValue: storage.listenerPorts.controlPort
            ), let uploadPort = NWEndpoint.Port(
                rawValue: storage.listenerPorts.uploadPort
            ) else {
                throw HarcHostError.invalidListenerPort(field: "resident")
            }
            let generationController = try HarcTransportGenerationController(
                controlPort: controlPort,
                uploadPort: uploadPort,
                bonjourHints: hints,
                driver: generationDriver
            )
            let recoveryBox = HarcResidentStartupRecoveryBox()
            let transport = try await HostTransportResidentRuntime.start(
                store: storage.hostStore,
                cryptographicStateStore: cryptographicStateStore,
                transportSetProtocol: HarcHostTransportSetProtocolAdapterV1(),
                generationBoundary: generationController,
                canonicalTuple: storage.tuple,
                beforeServing: {
                    let report = try await ingest.recoverPendingPublications()
                    await recoveryBox.store(report)
                }
            )
            startedTransport = transport
            let recovery = try await recoveryBox.requireReport()

            let backgroundProvider = try
                HarcResidentBackgroundCapabilityTransportProvider(
                    runtime: transport,
                    dnsServiceTarget: configuration.localDNSTarget,
                    uploadPort: storage.listenerPorts.uploadPort
                )
            try await backgroundTransportRelay.install(backgroundProvider)

            let endpoints = try pairingEndpoints(
                displayName: configuration.displayName,
                localDNSTarget: configuration.localDNSTarget,
                controlPort: storage.listenerPorts.controlPort
            )
            let remoteRelayHostAgent: HarcRemoteRelayHostAgent?
            if let remoteRelay = configuration.remoteRelay {
                remoteRelayHostAgent = await HarcRemoteRelayHostAgent.start(
                    configuration: remoteRelay
                )
            } else {
                remoteRelayHostAgent = nil
            }
            let pairingTickets = HarcForegroundPairingTicketControllerV1(
                storageRuntime: storage,
                transportRuntime: transport,
                endpoints: endpoints,
                remoteRelayHostAgent: remoteRelayHostAgent,
                remoteRelayRouteDeliveryBox:
                    remoteRelayRouteDeliveryBox
            )
            return HarcResidentHostRuntimeV1(
                storageRuntime: storage,
                transportRuntime: transport,
                canonicalIngest: ingest,
                pairingTickets: pairingTickets,
                pairingApproval: approval,
                remoteRelayHostAgent: remoteRelayHostAgent,
                remoteRelayRouteDeliveryBox:
                    remoteRelayRouteDeliveryBox,
                startupRecoveryReport: recovery
            )
        } catch {
            if let startedTransport { await startedTransport.shutdown() }
            if storage.enabledHostModeDuringStart {
                do {
                    try await storage.disableHostMode()
                } catch let rollbackError {
                    throw HarcResidentHostRuntimeError.startupRollbackFailed(
                        startup: String(describing: error),
                        rollback: String(describing: rollbackError)
                    )
                }
            }
            throw error
        }
    }

    private init(
        storageRuntime: HarcResidentHostStorageRuntime,
        transportRuntime: HostTransportResidentRuntime,
        canonicalIngest: HarcCanonicalIngestService,
        pairingTickets: HarcForegroundPairingTicketControllerV1,
        pairingApproval: HarcLocalPairingApprovalService,
        remoteRelayHostAgent: HarcRemoteRelayHostAgent?,
        remoteRelayRouteDeliveryBox: HarcRemoteRelayRouteDeliveryBox,
        startupRecoveryReport: HostCanonicalRecoveryReport
    ) {
        self.storageRuntime = storageRuntime
        self.transportRuntime = transportRuntime
        self.canonicalIngest = canonicalIngest
        self.pairingTickets = pairingTickets
        self.pairingApproval = pairingApproval
        self.remoteRelayHostAgent = remoteRelayHostAgent
        self.remoteRelayRouteDeliveryBox = remoteRelayRouteDeliveryBox
        self.startupRecoveryReport = startupRecoveryReport
        tuple = storageRuntime.tuple
        listenerPorts = storageRuntime.listenerPorts
    }

    public func issuePairingTicket(
        for clientKind: AdoptedClientKind
    ) async throws -> HarcForegroundPairingTicketV1 {
        guard !transportStopped else {
            throw HarcResidentHostRuntimeError.transportStopped
        }
        return try await pairingTickets.issue(for: clientKind)
    }

    public func cancelPairingTicket() async throws {
        try await pairingTickets.cancel()
    }

    public func pendingPairingClaim(
        _ claimID: UUID
    ) async throws -> HostPendingPairingClaim {
        try await pairingApproval.pendingClaim(claimID)
    }

    public func pendingPairingClaim(
        forTicketID ticketID: UUID
    ) async throws -> HostPendingPairingClaim? {
        try await pairingApproval.pendingClaim(forTicketID: ticketID)
    }

    @discardableResult
    public func approvePairingClaim(
        _ claimID: UUID,
        grantedScopes: [AuthorizationScope]? = nil
    ) async throws -> HostPairingIssuedGrant {
        let pending = try await pairingApproval.pendingClaim(claimID)
        let expectsRelayRoute = remoteRelayHostAgent != nil
        if expectsRelayRoute {
            await remoteRelayRouteDeliveryBox.beginProvisioning(
                forClaimID: claimID
            )
        }
        do {
            let grant = try await pairingApproval.approve(
                claimID,
                grantedScopes: grantedScopes
            )
            if expectsRelayRoute {
                try? await pairingTickets.provisionApprovedRelayRoute(
                    forTicketID: pending.ticketID,
                    claimID: claimID,
                    deviceID: grant.claims.deviceID
                )
                await remoteRelayRouteDeliveryBox.finishProvisioning(
                    forClaimID: claimID
                )
            }
            return grant
        } catch {
            if expectsRelayRoute {
                await remoteRelayRouteDeliveryBox.finishProvisioning(
                    forClaimID: claimID
                )
            }
            throw error
        }
    }

    public func denyPairingClaim(_ claimID: UUID) async throws {
        try await pairingApproval.deny(claimID)
    }

    /// Local Host-management projection of the durable device registry.
    public func pairedDevices() async throws -> [HostPairedDeviceSummary] {
        try await storageRuntime.hostStore.pairedDevices()
    }

    /// Revokes the authoritative Harc grant first, then removes the optional
    /// relay admission. Calling this again for an already-revoked device safely
    /// retries relay cleanup after a transient network failure.
    public func revokePairedDevice(_ deviceID: DeviceID) async throws {
        guard let entry = try await storageRuntime.hostStore
            .deviceRegistryEntry(deviceID: deviceID) else {
            throw HarcHostError.unknownDevice
        }
        if entry.status == .active {
            let revocationID = UUID()
            let evidence = try JSONEncoder().encode(
                HarcLocalDeviceRevocationEvidenceV1(
                    revocationID: revocationID,
                    deviceID: deviceID.description,
                    reasonCode: "user.revoked"
                )
            )
            try await storageRuntime.hostStore.revokeDevice(
                deviceID,
                revocationID: revocationID,
                reasonCode: "user.revoked",
                exactRevocationBytes: evidence
            )
        }
        if let route = try await remoteRelayRouteDeliveryBox.binding(
            forDeviceID: deviceID
        ) {
            try await remoteRelayHostAgent?.revoke(
                routeID: route.deviceRouteID
            )
            try await remoteRelayRouteDeliveryBox.removeBinding(
                forDeviceID: deviceID
            )
        }
    }

    public func recoverPendingPublications() async throws
        -> HostCanonicalRecoveryReport
    {
        try await canonicalIngest.recoverPendingPublications()
    }

    public func remoteRelayState() async
        -> HarcRemoteRelayHostConnectionState?
    {
        await remoteRelayHostAgent?.state()
    }

    public func validatedProcessingRequest(
        canonicalRecordingID: CanonicalRecordingID
    ) async throws -> HostDurableProcessingRequest {
        try await canonicalIngest.validatedProcessingRequest(
            canonicalRecordingID: canonicalRecordingID
        )
    }

    public func handleSystemWake() async {
        guard !transportStopped else { return }
        await transportRuntime.handleSystemWake()
        await remoteRelayHostAgent?.handleSystemWake()
    }

    /// Stops advertisement and both listeners while preserving the durable
    /// Host role. This is the correct path for application termination; the OS
    /// releases the writer lock, while the marker remains fail-closed.
    public func shutdown() async {
        guard !transportStopped else { return }
        transportStopped = true
        try? await pairingTickets.cancel()
        await remoteRelayHostAgent?.shutdown()
        await transportRuntime.shutdown()
    }

    /// Explicit role switch. Network admission is stopped first; only then is
    /// the canonical writer marker returned to Standalone and its lease freed.
    public func disableHostMode() async throws {
        guard !hostModeDisabled else { return }
        await shutdown()
        try await storageRuntime.disableHostMode()
        hostModeDisabled = true
    }

    private static func productionCapabilityPolicy() throws
        -> HarcCapabilityPolicyV1
    {
        try HarcCapabilityPolicyV1(
            supportedFeatureIDs: [],
            supportedDescriptorSchemaIDs: [
                ChunkDescriptorSchema.v1.rawValue,
            ],
            supportedEncodings: [.cafALAC]
        )
    }

    private static func productionCapabilityOffer()
        -> Harc_V1_CapabilityOfferV1
    {
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
        return offer
    }

    private static func pairingEndpoints(
        displayName: String,
        localDNSTarget: String,
        controlPort: UInt16
    ) throws -> [PairingEndpointV1] {
        [
            try .bonjourInstance(displayName),
            try .dnsHost(localDNSTarget.lowercased(), port: controlPort),
        ]
    }
}

private struct HarcLocalDeviceRevocationEvidenceV1: Encodable, Sendable {
    let format = "harc-local-device-revocation-v1"
    let revocationID: UUID
    let deviceID: String
    let reasonCode: String
}

public enum HarcResidentHostRuntimeError: Error, Equatable, Sendable {
    case transportStopped
    case startupRecoveryDidNotRun
    case startupRollbackFailed(startup: String, rollback: String)
}

extension HarcResidentHostRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transportStopped:
            "The resident Host transport is stopped."
        case .startupRecoveryDidNotRun:
            "Resident Host startup did not complete its pre-serving publication recovery."
        case .startupRollbackFailed(let startup, let rollback):
            "Resident Host startup failed (\(startup)) and its first-enable rollback failed (\(rollback))."
        }
    }
}

private actor HarcResidentStartupRecoveryBox {
    private var report: HostCanonicalRecoveryReport?

    func store(_ report: HostCanonicalRecoveryReport) {
        self.report = report
    }

    func requireReport() throws -> HostCanonicalRecoveryReport {
        guard let report else {
            throw HarcResidentHostRuntimeError.startupRecoveryDidNotRun
        }
        return report
    }
}
#endif
