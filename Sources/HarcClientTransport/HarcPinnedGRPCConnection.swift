#if canImport(Network)
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import HarcProtocol

public enum HarcPinnedGRPCConnectionStatus: Equatable, Sendable {
    case running
    case stoppingGracefully
    case stoppingImmediately
    case stoppedGracefully
    case stoppedImmediately
    case failed(String)
}

public enum HarcPinnedGRPCConnectionError: Error, Equatable, Sendable {
    case invalidEndpoint(field: String)
    case unexpectedTermination(String)
}

/// Owns the single task which runs a gRPC client's connections. Keeping this
/// state separate from the concrete transport makes shutdown and failure
/// behavior deterministic without opening a second production construction
/// path for pinned channels.
actor HarcClientConnectionTaskOwner {
    typealias RunConnections = @Sendable () async throws -> Void

    private enum ShutdownRequest {
        case none
        case graceful
        case immediate
    }

    private let beginGracefulShutdown: @Sendable () -> Void
    private var connectionTask: Task<Void, Never>?
    private var shutdownRequest = ShutdownRequest.none
    private var currentStatus = HarcPinnedGRPCConnectionStatus.running

    init(beginGracefulShutdown: @escaping @Sendable () -> Void) {
        self.beginGracefulShutdown = beginGracefulShutdown
    }

    func start(runConnections: @escaping RunConnections) async {
        precondition(
            connectionTask == nil,
            "A Harc gRPC connection task may only be started once"
        )
        await withCheckedContinuation { runEntry in
            connectionTask = Task {
                // This task inherits the owner's actor. Resuming here means
                // `start` cannot leave the actor until this task immediately
                // enters `runConnections` and reaches its first suspension.
                runEntry.resume()
                do {
                    try await runConnections()
                    self.connectionTaskFinished(errorDescription: nil)
                } catch {
                    self.connectionTaskFinished(
                        errorDescription: String(describing: error)
                    )
                }
            }
        }
    }

    func status() -> HarcPinnedGRPCConnectionStatus {
        currentStatus
    }

    func waitForTermination() async throws {
        let task = connectionTask
        await task?.value
        try throwUnexpectedTerminationIfNeeded()
    }

    func shutdownGracefully() async throws {
        switch currentStatus {
        case .running:
            shutdownRequest = .graceful
            currentStatus = .stoppingGracefully
            beginGracefulShutdown()
        case .stoppingGracefully,
             .stoppingImmediately,
             .stoppedGracefully,
             .stoppedImmediately,
             .failed:
            break
        }

        let task = connectionTask
        await task?.value
        try throwUnexpectedTerminationIfNeeded()
    }

    func shutdownImmediately() async {
        switch currentStatus {
        case .running, .stoppingGracefully:
            shutdownRequest = .immediate
            currentStatus = .stoppingImmediately
            connectionTask?.cancel()
        case .stoppingImmediately,
             .stoppedGracefully,
             .stoppedImmediately,
             .failed:
            break
        }

        let task = connectionTask
        await task?.value
    }

    private func connectionTaskFinished(errorDescription: String?) {
        switch shutdownRequest {
        case .none:
            currentStatus = .failed(
                errorDescription ?? "runConnections returned unexpectedly"
            )
        case .graceful:
            if let errorDescription {
                currentStatus = .failed(errorDescription)
            } else {
                currentStatus = .stoppedGracefully
            }
        case .immediate:
            currentStatus = .stoppedImmediately
        }
    }

    private func throwUnexpectedTerminationIfNeeded() throws {
        guard case .failed(let description) = currentStatus else {
            return
        }
        throw HarcPinnedGRPCConnectionError.unexpectedTermination(description)
    }
}

private typealias HarcGRPCTransport = HTTP2ClientTransport.TransportServices
private typealias HarcHostInfoGRPCClient = Harc_V1_HostInfoService.Client<HarcGRPCTransport>
private typealias HarcPairingGRPCClient = Harc_V1_PairingService.Client<HarcGRPCTransport>
private typealias HarcSessionGRPCClient = Harc_V1_SessionService.Client<HarcGRPCTransport>
private typealias HarcRecordingTransferGRPCClient = Harc_V1_RecordingTransferService.Client<
    HarcGRPCTransport
>
private typealias HarcLibraryGRPCClient = Harc_V1_LibraryService.Client<
    HarcGRPCTransport
>
private typealias HarcProcessingGRPCClient = Harc_V1_ProcessingService.Client<
    HarcGRPCTransport
>
private typealias HarcBootstrapGRPCAdapter = HarcGeneratedBootstrapRPCAdapter<
    HarcHostInfoGRPCClient,
    HarcPairingGRPCClient,
    HarcSessionGRPCClient
>
private typealias HarcRecordingTransferGRPCAdapter = HarcGeneratedRecordingTransferRPCAdapter<
    HarcRecordingTransferGRPCClient
>
private typealias HarcLibraryGRPCAdapter = HarcGeneratedLibraryRPCAdapter<
    HarcLibraryGRPCClient
>
private typealias HarcProcessingGRPCAdapter = HarcGeneratedProcessingRPCAdapter<
    HarcProcessingGRPCClient
>

/// The sole production owner for Harc's pinned foreground gRPC channel.
///
/// One factory invocation creates one TLS verifier, one stateless response
/// trust codec, one transport, and one `GRPCClient`. All generated bootstrap
/// and recording-transfer stubs wrap that exact client. Each bootstrap response
/// receives a client-authenticated trust envelope injected from its stream's
/// physical parent TLS connection,
/// so DNS failover or transport rotation cannot cross-label it. Pass this owner
/// itself to `HarcBootstrapClient`; its protocol conformance keeps the channel
/// lifecycle attached to every RPC use.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class HarcPinnedGRPCConnection:
    HarcBootstrapRPCTransport,
    HarcRecordingTransferRPCTransport,
    HarcLibraryRPCTransport,
    HarcProcessingRPCTransport,
    Sendable
{
    private let grpcClient: GRPCClient<HarcGRPCTransport>
    private let bootstrapRPCAdapter: HarcBootstrapGRPCAdapter
    private let recordingTransferRPCAdapter: HarcRecordingTransferGRPCAdapter
    private let libraryRPCAdapter: HarcLibraryGRPCAdapter
    private let processingRPCAdapter: HarcProcessingGRPCAdapter
    private let taskOwner: HarcClientConnectionTaskOwner

    private init(
        grpcClient: GRPCClient<HarcGRPCTransport>,
        bootstrapRPCAdapter: HarcBootstrapGRPCAdapter,
        recordingTransferRPCAdapter: HarcRecordingTransferGRPCAdapter,
        libraryRPCAdapter: HarcLibraryGRPCAdapter,
        processingRPCAdapter: HarcProcessingGRPCAdapter,
        taskOwner: HarcClientConnectionTaskOwner
    ) {
        self.grpcClient = grpcClient
        self.bootstrapRPCAdapter = bootstrapRPCAdapter
        self.recordingTransferRPCAdapter = recordingTransferRPCAdapter
        self.libraryRPCAdapter = libraryRPCAdapter
        self.processingRPCAdapter = processingRPCAdapter
        self.taskOwner = taskOwner
    }

    /// Starts a dedicated pinned connection to a host name or IP address.
    /// `serverHostname` controls TLS SNI and defaults to `host`; Harc identity
    /// acceptance still comes exclusively from the authority-signed transport
    /// set verifier rather than public-PKI hostname validation.
    public static func connect(
        host: String,
        port: Int,
        serverHostname: String? = nil,
        trustCoordinator: HarcTransportTrustCoordinator
    ) async throws -> HarcPinnedGRPCConnection {
        guard !host.isEmpty else {
            throw HarcPinnedGRPCConnectionError.invalidEndpoint(field: "host")
        }
        guard (1 ... 65_535).contains(port) else {
            throw HarcPinnedGRPCConnectionError.invalidEndpoint(field: "port")
        }
        let resolvedServerHostname = serverHostname ?? host
        guard !resolvedServerHostname.isEmpty else {
            throw HarcPinnedGRPCConnectionError.invalidEndpoint(
                field: "serverHostname"
            )
        }

        return try await make(
            target: .dns(host: host, port: port),
            serverHostname: resolvedServerHostname,
            trustCoordinator: trustCoordinator
        )
    }

    public func getHostInfo(
        _ request: Harc_V1_GetHostInfoRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetHostInfoResponseV1> {
        try await bootstrapRPCAdapter.getHostInfo(request)
    }

    public func negotiateCapabilities(
        _ request: Harc_V1_NegotiateCapabilitiesRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_NegotiateCapabilitiesResponseV1> {
        try await bootstrapRPCAdapter.negotiateCapabilities(request)
    }

    public func beginPairingClaim(
        _ request: Harc_V1_BeginPairingClaimRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginPairingClaimResponseV1> {
        try await bootstrapRPCAdapter.beginPairingClaim(request)
    }

    public func provePairingClaim(
        _ request: Harc_V1_ProvePairingClaimRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_ProvePairingClaimResponseV1> {
        try await bootstrapRPCAdapter.provePairingClaim(
            request,
            claimantToken: claimantToken
        )
    }

    public func getPairingStatus(
        _ request: Harc_V1_GetPairingStatusRequestV1,
        claimantToken: Data
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_GetPairingStatusResponseV1> {
        try await bootstrapRPCAdapter.getPairingStatus(
            request,
            claimantToken: claimantToken
        )
    }

    public func beginSession(
        _ request: Harc_V1_BeginSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_BeginSessionResponseV1> {
        try await bootstrapRPCAdapter.beginSession(request)
    }

    public func openSession(
        _ request: Harc_V1_OpenSessionRequestV1
    ) async throws -> HarcBootstrapRPCResponse<Harc_V1_OpenSessionResponseV1> {
        try await bootstrapRPCAdapter.openSession(request)
    }

    public func beginUpload(
        _ request: Harc_V1_BeginUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_BeginUploadResponseV1 {
        try await recordingTransferRPCAdapter.beginUpload(
            request,
            authorization: authorization
        )
    }

    public func declareChunks(
        _ request: Harc_V1_DeclareChunksRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_DeclareChunksResponseV1 {
        try await recordingTransferRPCAdapter.declareChunks(
            request,
            authorization: authorization
        )
    }

    public func uploadChunks(
        authorization: HarcRecordingTransferAuthorization,
        requestProducer: @escaping HarcUploadChunkRequestProducer,
        responseConsumer: @escaping HarcUploadChunkResponseConsumer
    ) async throws {
        try await recordingTransferRPCAdapter.uploadChunks(
            authorization: authorization,
            requestProducer: requestProducer,
            responseConsumer: responseConsumer
        )
    }

    public func reconcileUpload(
        _ request: Harc_V1_ReconcileUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_ReconcileUploadResponseV1 {
        try await recordingTransferRPCAdapter.reconcileUpload(
            request,
            authorization: authorization
        )
    }

    public func commitUpload(
        _ request: Harc_V1_CommitUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_CommitUploadResponseV1 {
        try await recordingTransferRPCAdapter.commitUpload(
            request,
            authorization: authorization
        )
    }

    public func abandonUpload(
        _ request: Harc_V1_AbandonUploadRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_AbandonUploadResponseV1 {
        try await recordingTransferRPCAdapter.abandonUpload(
            request,
            authorization: authorization
        )
    }

    public func getRecordingStatus(
        _ request: Harc_V1_GetRecordingStatusRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_GetRecordingStatusResponseV1 {
        try await recordingTransferRPCAdapter.getRecordingStatus(
            request,
            authorization: authorization
        )
    }

    public func mintBackgroundUploadAuthorization(
        _ request: Harc_V1_MintBackgroundCapabilityRequestV1,
        authorization: HarcRecordingTransferAuthorization
    ) async throws -> Harc_V1_MintBackgroundCapabilityResponseV1 {
        try await recordingTransferRPCAdapter
            .mintBackgroundUploadAuthorization(
                request,
                authorization: authorization
            )
    }

    public func beginLibrarySnapshot(
        _ request: Harc_V1_BeginLibrarySnapshotRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_BeginLibrarySnapshotResponseV1 {
        try await libraryRPCAdapter.beginLibrarySnapshot(
            request,
            authorization: authorization
        )
    }

    public func listSnapshotPage(
        _ request: Harc_V1_ListSnapshotPageRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ListSnapshotPageResponseV1 {
        try await libraryRPCAdapter.listSnapshotPage(
            request,
            authorization: authorization
        )
    }

    public func listLibraryChanges(
        _ request: Harc_V1_ListChangesRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ListChangesResponseV1 {
        try await libraryRPCAdapter.listLibraryChanges(
            request,
            authorization: authorization
        )
    }

    public func getLibraryRecording(
        _ request: Harc_V1_GetRecordingRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_GetRecordingResponseV1 {
        try await libraryRPCAdapter.getLibraryRecording(
            request,
            authorization: authorization
        )
    }

    public func getLibraryAudio(
        _ request: Harc_V1_GetAudioRequestV1,
        authorization: HarcLibraryAuthorization,
        responseConsumer: @escaping HarcLibraryAudioResponseConsumer
    ) async throws {
        try await libraryRPCAdapter.getLibraryAudio(
            request,
            authorization: authorization,
            responseConsumer: responseConsumer
        )
    }

    public func searchLibraryMetadata(
        _ request: Harc_V1_SearchMetadataRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_SearchMetadataResponseV1 {
        try await libraryRPCAdapter.searchLibraryMetadata(
            request,
            authorization: authorization
        )
    }

    public func searchLibraryTranscripts(
        _ request: Harc_V1_SearchTranscriptsRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_SearchTranscriptsResponseV1 {
        try await libraryRPCAdapter.searchLibraryTranscripts(
            request,
            authorization: authorization
        )
    }

    public func applyLibraryMetadataMutation(
        _ request: Harc_V1_ApplyMetadataMutationRequestV1,
        authorization: HarcLibraryAuthorization
    ) async throws -> Harc_V1_ApplyMetadataMutationResponseV1 {
        try await libraryRPCAdapter.applyLibraryMetadataMutation(
            request,
            authorization: authorization
        )
    }

    public func submitOwnArtifact(
        authorization: HarcProcessingAuthorization,
        requestProducer: @escaping HarcProcessingRequestProducer
    ) async throws -> Harc_V1_SubmitOwnArtifactResponseV1 {
        try await processingRPCAdapter.submitOwnArtifact(
            authorization: authorization,
            requestProducer: requestProducer
        )
    }

    public func getProcessingStatus(
        _ request: Harc_V1_GetProcessingStatusRequestV1,
        authorization: HarcProcessingAuthorization
    ) async throws -> Harc_V1_GetProcessingStatusResponseV1 {
        try await processingRPCAdapter.getProcessingStatus(
            request,
            authorization: authorization
        )
    }

    public func status() async -> HarcPinnedGRPCConnectionStatus {
        await taskOwner.status()
    }

    /// Waits for an explicit shutdown or surfaces an unexpected connection-task
    /// return/failure. Callers supervising a long-lived host link should keep a
    /// task awaiting this method.
    public func waitForTermination() async throws {
        try await taskOwner.waitForTermination()
    }

    /// Stops accepting new RPCs and waits for in-flight RPCs to drain.
    public func shutdownGracefully() async throws {
        try await taskOwner.shutdownGracefully()
    }

    /// Cancels the connection task and any in-flight RPCs.
    public func shutdownImmediately() async {
        await taskOwner.shutdownImmediately()
    }

    deinit {
        // Explicit shutdown is preferred. This is a fail-safe so dropping the
        // owner cannot leave its transport reconnecting indefinitely.
        grpcClient.beginGracefulShutdown()
    }

    private static func make(
        target: any ResolvableTarget,
        serverHostname: String,
        trustCoordinator: HarcTransportTrustCoordinator
    ) async throws -> HarcPinnedGRPCConnection {
        let tls = try HarcPinnedGRPCTLS(
            serverHostname: serverHostname,
            trustCoordinator: trustCoordinator
        )
        let transport = try tls.makeTransport(target: target)
        let grpcClient = GRPCClient(transport: transport)

        let bootstrapRPCAdapter = HarcBootstrapGRPCAdapter(
            hostInfoClient: HarcHostInfoGRPCClient(wrapping: grpcClient),
            pairingClient: HarcPairingGRPCClient(wrapping: grpcClient),
            sessionClient: HarcSessionGRPCClient(wrapping: grpcClient),
            responseTrustCodec: tls.responseTrustCodec
        )
        let recordingTransferRPCAdapter = HarcRecordingTransferGRPCAdapter(
            client: HarcRecordingTransferGRPCClient(wrapping: grpcClient)
        )
        let libraryRPCAdapter = HarcLibraryGRPCAdapter(
            client: HarcLibraryGRPCClient(wrapping: grpcClient)
        )
        let processingRPCAdapter = HarcProcessingGRPCAdapter(
            client: HarcProcessingGRPCClient(wrapping: grpcClient)
        )
        let taskOwner = HarcClientConnectionTaskOwner(
            beginGracefulShutdown: {
                grpcClient.beginGracefulShutdown()
            }
        )
        let connection = HarcPinnedGRPCConnection(
            grpcClient: grpcClient,
            bootstrapRPCAdapter: bootstrapRPCAdapter,
            recordingTransferRPCAdapter: recordingTransferRPCAdapter,
            libraryRPCAdapter: libraryRPCAdapter,
            processingRPCAdapter: processingRPCAdapter,
            taskOwner: taskOwner
        )
        await taskOwner.start {
            try await grpcClient.runConnections()
        }
        return connection
    }
}
#endif
