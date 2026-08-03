#if canImport(Network)
import Foundation
import HarcDomain
@testable import HarcHost
@testable import HarcHostTransport
import HarcIdentity
import HarcTransfer

struct UnavailableRecordingTransferFactoryApplication:
    HarcRecordingTransferRPCApplication
{
    func beginUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: BeginHostUploadRequest
    ) async throws -> BeginHostUploadDisposition {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func declareChunks(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        descriptors: [LogicalChunkDescriptor]
    ) async throws -> ChunkDeclarationDisposition {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func uploadChunk(
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
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func reconcileUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> UploadReconciliation {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func commitUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256,
        exactSignedManifestBytes: Data
    ) async throws -> HostCanonicalCommitDisposition {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func abandonUpload(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        uploadID: UploadID,
        generation: UploadGeneration,
        expectedUploadProfileSHA256: UploadProfileSHA256
    ) async throws -> HostAbandonUploadResult {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func getRecordingStatus(
        context: AuthenticatedDeviceContext,
        key: HostRecordingStatusKey
    ) async throws -> HostRecordingStatusResult {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }

    func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        sessionCapabilities: HostTransferSessionCapabilities,
        request: HostBackgroundCapabilityMintRequest
    ) async throws -> HostBackgroundCapabilityMintResult {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }
}

struct UnavailableRecordingTransferFactoryAuthenticator:
    HarcSessionCredentialAuthenticating
{
    func authenticate(
        credential: Data,
        tlsSPKISHA256: Data,
        requiredScope: AuthorizationScope?
    ) async throws -> HostAuthenticatedSession {
        throw RecordingTransferFactoryTestDoubleError.unexpectedCall
    }
}

enum RecordingTransferFactoryTestDoubleError: Error {
    case unexpectedCall
}
#endif
