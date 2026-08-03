import Foundation
import HarcDomain
import HarcIdentity
import HarcTransfer

/// Transport-neutral composition for the authenticated recording upload RPCs.
/// Every continuation proves compatibility with the upload's frozen transfer
/// profile before entering the authoritative store or canonical ingest actor.
public struct HostRecordingTransferService: Sendable {
    private let hostStore: HarcHostStore
    private let canonicalIngest: HarcCanonicalIngestService
    private let backgroundCapabilityTransportSnapshotProvider:
        any HostBackgroundCapabilityTransportSnapshotProviding
    private let backgroundCapabilityPolicy: HostBackgroundCapabilityPolicy

    public init(
        hostStore: HarcHostStore,
        canonicalIngest: HarcCanonicalIngestService,
        backgroundCapabilityTransportSnapshotProvider:
            any HostBackgroundCapabilityTransportSnapshotProviding,
        backgroundCapabilityPolicy: HostBackgroundCapabilityPolicy = .standard
    ) {
        self.hostStore = hostStore
        self.canonicalIngest = canonicalIngest
        self.backgroundCapabilityTransportSnapshotProvider =
            backgroundCapabilityTransportSnapshotProvider
        self.backgroundCapabilityPolicy = backgroundCapabilityPolicy
    }

    public func beginUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition {
        try await canonicalIngest.beginUpload(
            context: context,
            sessionCapabilities: sessionCapabilities,
            request: request
        )
    }

    public func declareChunks(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        descriptors: [LogicalChunkDescriptor]
    ) async throws -> ChunkDeclarationDisposition {
        try await validateContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
        return try await hostStore.declareChunks(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256,
            descriptors: descriptors
        )
    }

    public func uploadChunk(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        chunkIndex: UInt32,
        claimedChunkID: ChunkID,
        declaredEncodedLength: UInt64,
        claimedEncodedSHA256: EncodedChunkSHA256,
        body: HostChunkBody
    ) async throws -> StagedChunkDisposition {
        try await validateContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
        return try await hostStore.stageChunk(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256,
            chunkIndex: chunkIndex,
            claimedChunkID: claimedChunkID,
            declaredEncodedLength: declaredEncodedLength,
            claimedEncodedSHA256: claimedEncodedSHA256,
            body: body
        )
    }

    public func reconcileUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> UploadReconciliation {
        try await validateContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
        return try await canonicalIngest.reconcileUpload(
            for: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256,
            context: context
        )
    }

    public func commitUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        exactSignedManifestBytes: Data
    ) async throws -> HostCanonicalCommitDisposition {
        try await validateContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
        let manifest = try await canonicalIngest
            .validateAndBindFinalManifestForPrecommit(
                context: context,
                uploadID: uploadID,
                generation: generation,
                expectedUploadProfileSHA256: expectedUploadProfileSHA256,
                exactSignedManifestBytes: exactSignedManifestBytes
            )
        let missing: [UInt32]
        switch manifest {
        case .bound(let indexes), .exactReplay(let indexes):
            missing = indexes
        }
        guard missing.isEmpty else {
            throw HarcHostError.incompleteCanonicalUpload
        }
        return try await canonicalIngest.commitUploadWithDisposition(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
    }

    public func abandonUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostAbandonUploadResult {
        try await validateContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
        return try await hostStore.abandonUpload(
            context: context,
            uploadID: uploadID,
            generation: generation,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
    }

    public func getRecordingStatus(
        context: AuthenticatedDeviceContext,
        key: HostRecordingStatusKey
    ) async throws -> HostRecordingStatusResult {
        try await hostStore.recordingStatus(for: key, context: context)
    }

    public func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: HostBackgroundCapabilityMintRequest
    ) async throws -> HostBackgroundCapabilityMintResult {
        try await validateContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: request.uploadID,
            expectedUploadProfileSHA256: request.uploadProfileSHA256
        )
        return try await hostStore.mintBackgroundCapability(
            context: context,
            request: request,
            transportSnapshotProvider:
                backgroundCapabilityTransportSnapshotProvider,
            policy: backgroundCapabilityPolicy
        )
    }

    private func validateContinuation(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws {
        try await hostStore.validateTransferContinuation(
            context: context,
            sessionCapabilities: sessionCapabilities,
            uploadID: uploadID,
            expectedUploadProfileSHA256: expectedUploadProfileSHA256
        )
    }
}
