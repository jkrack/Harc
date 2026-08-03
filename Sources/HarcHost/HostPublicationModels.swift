import Foundation
import HarcDomain
import HarcIdentity
import HarcStore
import HarcTransfer

struct HostDurableStagedChunk: Sendable {
    let descriptor: LogicalChunkDescriptor
    let relativePath: String
}

struct HostCanonicalPublicationWork: Sendable {
    let attempt: UploadAttempt
    let capture: ChunkedFinalizedCapture
    let checkpoint: HostUploadJournalState
    let canonicalRecordingID: CanonicalRecordingID
    let publicationRelativePath: String
    let temporaryName: String
    let stagedChunks: [HostDurableStagedChunk]
    let authorizedDeviceID: DeviceID
    let authorizedGrantID: GrantID
    let authorizedGrantEpoch: GrantEpoch
    let acceptedUploadGeneration: UploadGeneration
    let authorizationAcceptedAt: Date
    let exactPersistedReceipt: OpaqueExactObjectSlot?
    let receiptID: UUID?
    let canonicalRevision: EntityRevision?
    let changeCursor: ChangeCursor?
    let durableCommitTime: Date?
    let canonicalArtifactIdentity: HostCanonicalArtifactIdentity?
}

enum HostCanonicalPublicationPreparation: Sendable {
    case alreadyReceipted(OpaqueExactObjectSlot)
    case work(HostCanonicalPublicationWork)
}

/// Distinguishes the first successful canonical publication from a durable
/// receipt replay. The exact receipt bytes are identical in both cases; the
/// disposition lets the transport report idempotency without guessing from
/// manifest-binding state.
public enum HostCanonicalCommitDisposition: Equatable, Sendable {
    case committed(OpaqueExactObjectSlot)
    case exactReplay(OpaqueExactObjectSlot)

    public var exactReceipt: OpaqueExactObjectSlot {
        switch self {
        case .committed(let receipt), .exactReplay(let receipt): receipt
        }
    }
}

public enum HostPublicationFailurePoint: String, Codable, CaseIterable, Sendable {
    case afterPublicationPlan
    case afterTemporaryFileCreation
    case afterCanonicalAssembly
    case afterTemporaryFileSynchronization
    case afterAudioRename
    case afterAudioDirectorySynchronization
    case afterCanonicalDatabaseCommit
    case afterHostPublicationLinkage
    case afterReceiptCreation
    case afterReceiptPersistence
    case afterManifestSidecarPublication
    case afterReceiptSidecarPublication
    case afterReceiptDirectorySynchronization
    case afterReceiptedCommit
    case beforeProcessingSchedule
    case afterProcessingScheduleBeforeCheckpoint
}

public protocol HostPublicationFailureInjector: Sendable {
    func hit(_ point: HostPublicationFailurePoint) async throws
}

public struct NoHostPublicationFailureInjector: HostPublicationFailureInjector {
    public init() {}
    public func hit(_ point: HostPublicationFailurePoint) async throws {}
}

/// Complete durable binding handed to derived processing. The scheduler must
/// treat the artifact identity and PCM claims as part of its idempotency key,
/// and must revalidate the path binding before daemon ingestion.
public struct HostDurableProcessingRequest: Equatable, Sendable {
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalWAVURL: URL
    public let canonicalPCMHash: CanonicalPCMHash
    public let canonicalPCMFrames: UInt64
    public let artifactIdentity: HostCanonicalArtifactIdentity

    public init(
        canonicalRecordingID: CanonicalRecordingID,
        canonicalWAVURL: URL,
        canonicalPCMHash: CanonicalPCMHash,
        canonicalPCMFrames: UInt64,
        artifactIdentity: HostCanonicalArtifactIdentity
    ) throws {
        let layout = try HostCanonicalWAVLayout(totalFrames: canonicalPCMFrames)
        guard canonicalWAVURL.isFileURL,
              canonicalWAVURL.path.hasPrefix("/"),
              canonicalWAVURL.standardizedFileURL.path == canonicalWAVURL.path,
              artifactIdentity.fileByteCount == layout.fileByteCount
        else { throw HarcHostError.canonicalArtifactIdentityMismatch }
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalWAVURL = canonicalWAVURL
        self.canonicalPCMHash = canonicalPCMHash
        self.canonicalPCMFrames = canonicalPCMFrames
        self.artifactIdentity = artifactIdentity
    }
}

public protocol HostReceiptDurableProcessingScheduling: Sendable {
    /// Implementations MUST durably enqueue idempotently by
    /// `canonicalRecordingID`. A process may die after this returns but before
    /// HarcHost checkpoints the handoff, so replay of the same ID is expected.
    func schedule(_ request: HostDurableProcessingRequest) async throws
}

/// Default is intentionally visible failure, not a false successful processing
/// handoff. App composition injects the daemon-backed scheduler before Host
/// mode is exposed.
public struct UnavailableHostProcessingScheduler: HostReceiptDurableProcessingScheduling {
    public init() {}

    public func schedule(_ request: HostDurableProcessingRequest) async throws {
        throw HarcHostError.processingSchedulerUnavailable
    }
}
