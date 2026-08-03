import Foundation
import HarcHost
import HarcIdentity
import HarcProtocol
import HarcTransfer
#if canImport(Darwin)
import Darwin
#endif

public enum HarcBackgroundBatchIngestFailurePoint:
    String,
    CaseIterable,
    Sendable
{
    case afterRollbackChunkWrite
    case afterWholeBodyVerification
    case afterChunkStaged
    case afterAcknowledgementIssued
    case afterAcknowledgementPersisted
}

public protocol HarcBackgroundBatchIngestFailureInjecting: Sendable {
    func hit(_ point: HarcBackgroundBatchIngestFailurePoint) throws
}

public struct NoHarcBackgroundBatchIngestFailureInjector:
    HarcBackgroundBatchIngestFailureInjecting,
    Sendable
{
    public init() {}
    public func hit(_ point: HarcBackgroundBatchIngestFailurePoint) throws {}
}

public protocol HarcBackgroundBatchAcknowledgementIDGenerating: Sendable {
    func generateAcknowledgementID() -> UUID
}

public struct SystemHarcBackgroundBatchAcknowledgementIDGenerator:
    HarcBackgroundBatchAcknowledgementIDGenerating,
    Sendable
{
    public init() {}
    public func generateAcknowledgementID() -> UUID { UUID() }
}

public enum HarcBackgroundBatchIngestError: Error, Equatable, Sendable {
    case invalidRollbackRoot
    case invalidServingGenerationBinding
    case rollbackIO(operation: String, code: Int32)
    case immutableDescriptorMismatch
    case stagedAcknowledgementMismatch
}

/// Opaque proof that a request arrived on one lifecycle-owned upload listener.
/// External transport adapters can carry this value but cannot construct or
/// relabel it with a caller-supplied epoch.
public struct HarcBackgroundUploadServingGenerationBinding:
    Equatable,
    Sendable
{
    package let generationID: UUID
    package let transportSetEpoch: UInt64

    package init(generationID: UUID, transportSetEpoch: UInt64) throws {
        guard generationID != Self.zeroUUID, transportSetEpoch > 0 else {
            throw HarcBackgroundBatchIngestError
                .invalidServingGenerationBinding
        }
        self.generationID = generationID
        self.transportSetEpoch = transportSetEpoch
    }

    package func requireGeneration(_ expectedGenerationID: UUID) throws {
        guard generationID == expectedGenerationID else {
            throw HarcBackgroundBatchIngestError
                .invalidServingGenerationBinding
        }
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}

/// HTTP-framework-neutral HARCAB1 ingestion. The caller owns the already-
/// received secure input file. Scanner callback bytes stay in a private,
/// rollback-only namespace until the complete capability body hash succeeds.
public struct HarcBackgroundBatchIngestApplicationV1: Sendable {
    private static let stagingFragmentBytes = 256 * 1_024

    private let hostStore: HarcHostStore
    private let rollbackRoot: URL
    private let hostTrust: RecordingHostTrustBinding
    private let hostAuthoritySigner: any P256DigestSigner
    private let acknowledgementCodec = HarcBatchAcknowledgementCodecV1()
    private let acknowledgementIDGenerator:
        any HarcBackgroundBatchAcknowledgementIDGenerating
    private let failureInjector: any HarcBackgroundBatchIngestFailureInjecting
    private let supportedRequiredFeatures: Set<String>
    private let versionPolicy: HarcProtocolVersionPolicy
    private let now: @Sendable () -> Date

    public init(
        hostStore: HarcHostStore,
        rollbackRoot: URL,
        hostTrust: RecordingHostTrustBinding,
        hostAuthoritySigner: any P256DigestSigner,
        acknowledgementIDGenerator:
            any HarcBackgroundBatchAcknowledgementIDGenerating =
                SystemHarcBackgroundBatchAcknowledgementIDGenerator(),
        failureInjector: any HarcBackgroundBatchIngestFailureInjecting =
            NoHarcBackgroundBatchIngestFailureInjector(),
        supportedRequiredFeatures: Set<String> = [],
        versionPolicy: HarcProtocolVersionPolicy = .currentV1,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard rollbackRoot.isFileURL,
              rollbackRoot.standardizedFileURL.path == rollbackRoot.path,
              hostAuthoritySigner.publicKey == hostTrust.hostAuthorityPublicKey
        else {
            throw HarcBackgroundBatchIngestError.invalidRollbackRoot
        }
        try FileManager.default.createDirectory(
            at: rollbackRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if canImport(Darwin)
        var rollbackRootInformation = stat()
        guard lstat(rollbackRoot.path, &rollbackRootInformation) == 0,
              (rollbackRootInformation.st_mode & S_IFMT) == S_IFDIR,
              rollbackRootInformation.st_uid == geteuid(),
              (rollbackRootInformation.st_mode & 0o077) == 0 else {
            throw HarcBackgroundBatchIngestError.invalidRollbackRoot
        }
        #endif
        self.hostStore = hostStore
        self.rollbackRoot = rollbackRoot
        self.hostTrust = hostTrust
        self.hostAuthoritySigner = hostAuthoritySigner
        self.acknowledgementIDGenerator = acknowledgementIDGenerator
        self.failureInjector = failureInjector
        self.supportedRequiredFeatures = supportedRequiredFeatures
        self.versionPolicy = versionPolicy
        self.now = now
    }

    /// Phase-one header admission. The serving epoch is supplied only by the
    /// opaque lifecycle generation binding; no request header can assert it.
    public func admit(
        _ request: HostBackgroundCapabilityAdmissionRequest,
        servedBy servingGeneration:
            HarcBackgroundUploadServingGenerationBinding
    ) async throws -> HostBackgroundBatchAdmission {
        try await hostStore.admitBackgroundCapability(
            request,
            servedTransportSetEpoch: servingGeneration.transportSetEpoch
        )
    }

    public func ingest(
        secureTemporaryBodyURL: URL,
        admission: HostBackgroundBatchAdmission
    ) async throws -> HostBackgroundBatchReplay {
        guard secureTemporaryBodyURL.isFileURL else {
            throw HarcProtocolCodecError.invalidEndpoint(
                field: "audioBatch.fileURL"
            )
        }
        let namespace = try HarcBackgroundRollbackNamespace.create(
            under: rollbackRoot
        )
        defer { namespace.remove() }

        var rollbackChunks: [HarcBackgroundRollbackChunk] = []
        rollbackChunks.reserveCapacity(admission.batch.chunks.count)
        var nextExpectedChunk = 0
        let scan = try HarcAudioBatchFileV1.scan(
            at: secureTemporaryBodyURL,
            expectedGeneration: admission.batch.generation,
            expectedExactBodyByteLength: admission.contentLength,
            expectedExactBodySHA256: admission.exactBodySHA256,
            supportedRequiredFeatures: supportedRequiredFeatures,
            versionPolicy: versionPolicy
        ) { scannedChunk in
            guard nextExpectedChunk < admission.batch.chunks.count,
                  scannedChunk.descriptor
                    == admission.batch.chunks[nextExpectedChunk] else {
                throw HarcBackgroundBatchIngestError
                    .immutableDescriptorMismatch
            }
            let stored = try namespace.write(
                scannedChunk.encodedBytes,
                descriptor: scannedChunk.descriptor,
                ordinal: nextExpectedChunk
            )
            rollbackChunks.append(stored)
            nextExpectedChunk += 1
            try failureInjector.hit(.afterRollbackChunkWrite)
        }
        guard scan.descriptor == admission.batch,
              nextExpectedChunk == admission.batch.chunks.count,
              rollbackChunks.count == admission.batch.chunks.count else {
            throw HarcBackgroundBatchIngestError.immutableDescriptorMismatch
        }
        try failureInjector.hit(.afterWholeBodyVerification)

        let verifiedBody = try await hostStore
            .finalizeBackgroundCapabilityVerifiedBody(
                admission,
                observedBodyLength: scan.descriptor.exactBodyByteLength,
                observedBodySHA256: scan.descriptor.exactBodySHA256
            )
        switch verifiedBody {
        case .exactReplay(let replay):
            return replay
        case .stagingRequired:
            break
        }

        for rollbackChunk in rollbackChunks {
            let fragments = try rollbackChunk.readBoundedFragments(
                maximumFragmentBytes: Self.stagingFragmentBytes
            )
            let staged = try await hostStore.stageBackgroundCapabilityChunk(
                admission,
                descriptor: rollbackChunk.descriptor,
                body: .fragments(fragments)
            )
            switch staged {
            case .batchAlreadyAccepted:
                return try await releaseExactReplayAfterStagingRace(
                    admission: admission,
                    scan: scan
                )
            case .staged(let disposition):
                let acknowledgement: HostDurableChunkAcknowledgement
                switch disposition {
                case .durablyAccepted(let value), .exactReplay(let value):
                    acknowledgement = value
                }
                let expected = DurableChunkStatus(
                    chunkIndex: rollbackChunk.descriptor.chunkIndex,
                    chunkID: rollbackChunk.descriptor.chunkID,
                    encodedSHA256: rollbackChunk.descriptor.encodedSHA256
                )
                guard acknowledgement.uploadID == admission.batch.uploadID,
                      acknowledgement.generation
                        == admission.batch.generation,
                      acknowledgement.uploadProfileSHA256
                        == admission.batch.uploadProfileSHA256,
                      acknowledgement.durableChunk == expected else {
                    throw HarcBackgroundBatchIngestError
                        .stagedAcknowledgementMismatch
                }
            }
            try failureInjector.hit(.afterChunkStaged)
        }

        let acknowledgement = try acknowledgementCodec.issueBatchAcknowledgement(
            claims: BatchAcknowledgementClaims(
                hostTrust: hostTrust,
                batch: admission.batch,
                acknowledgementID:
                    acknowledgementIDGenerator.generateAcknowledgementID(),
                durableAt: Self.backgroundWireDate(now())
            ),
            hostAuthoritySigner: hostAuthoritySigner
        )
        try failureInjector.hit(.afterAcknowledgementIssued)
        let finalized = try await hostStore
            .finalizeBackgroundCapabilityAcceptance(
                admission,
                observedBodyLength: scan.descriptor.exactBodyByteLength,
                observedBodySHA256: scan.descriptor.exactBodySHA256,
                acknowledgement: acknowledgement
            )
        let replay: HostBackgroundBatchReplay
        switch finalized {
        case .accepted(let value), .exactReplay(let value):
            replay = value
        }
        try failureInjector.hit(.afterAcknowledgementPersisted)
        return replay
    }

    private func releaseExactReplayAfterStagingRace(
        admission: HostBackgroundBatchAdmission,
        scan: HarcAudioBatchFileScanV1
    ) async throws -> HostBackgroundBatchReplay {
        let finalized = try await hostStore
            .finalizeBackgroundCapabilityVerifiedBody(
                admission,
                observedBodyLength: scan.descriptor.exactBodyByteLength,
                observedBodySHA256: scan.descriptor.exactBodySHA256
            )
        guard case .exactReplay(let replay) = finalized else {
            throw HarcBackgroundBatchIngestError
                .stagedAcknowledgementMismatch
        }
        return replay
    }

    private static func backgroundWireDate(_ date: Date) -> Date {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite else { return date }
        return Date(
            timeIntervalSince1970: milliseconds.rounded(.down) / 1_000
        )
    }
}

private struct HarcBackgroundRollbackChunk: Sendable {
    let url: URL
    let descriptor: LogicalChunkDescriptor

    func readBoundedFragments(maximumFragmentBytes: Int) throws -> [Data] {
        guard maximumFragmentBytes > 0,
              descriptor.encodedByteLength
                <= UInt64(HarcAudioBatchV1.maximumEntryBytes) else {
            throw HarcBackgroundBatchIngestError
                .immutableDescriptorMismatch
        }
        let data = try Data(contentsOf: url, options: .uncached)
        guard UInt64(data.count) == descriptor.encodedByteLength else {
            throw HarcBackgroundBatchIngestError
                .immutableDescriptorMismatch
        }
        var fragments: [Data] = []
        fragments.reserveCapacity(
            (data.count + maximumFragmentBytes - 1) / maximumFragmentBytes
        )
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + maximumFragmentBytes)
            fragments.append(Data(data[offset ..< end]))
            offset = end
        }
        return fragments
    }
}

private final class HarcBackgroundRollbackNamespace: @unchecked Sendable {
    private let url: URL

    private init(url: URL) {
        self.url = url
    }

    static func create(under root: URL) throws -> HarcBackgroundRollbackNamespace {
        #if canImport(Darwin)
        var template = Array(
            root.appendingPathComponent(
                "harc-background-rollback-XXXXXX",
                isDirectory: true
            ).path.utf8CString
        )
        let createdPath: String? = template.withUnsafeMutableBufferPointer {
            guard let pointer = $0.baseAddress,
                  let created = mkdtemp(pointer) else { return nil }
            let bytes = UnsafeBufferPointer(
                start: created,
                count: strlen(created)
            ).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        guard let createdPath else {
            throw HarcBackgroundBatchIngestError.rollbackIO(
                operation: "mkdtemp",
                code: errno
            )
        }
        let url = URL(fileURLWithPath: createdPath, isDirectory: true)
        guard createdPath.withCString({ chmod($0, S_IRWXU) }) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: url)
            throw HarcBackgroundBatchIngestError.rollbackIO(
                operation: "chmod",
                code: code
            )
        }
        return HarcBackgroundRollbackNamespace(url: url)
        #else
        throw HarcBackgroundBatchIngestError.invalidRollbackRoot
        #endif
    }

    func write(
        _ data: Data,
        descriptor: LogicalChunkDescriptor,
        ordinal: Int
    ) throws -> HarcBackgroundRollbackChunk {
        #if canImport(Darwin)
        let fileURL = url.appendingPathComponent(
            String(format: "chunk-%08d.bin", ordinal),
            isDirectory: false
        )
        let fileDescriptor = fileURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard fileDescriptor >= 0 else {
            throw HarcBackgroundBatchIngestError.rollbackIO(
                operation: "open",
                code: errno
            )
        }
        defer { Darwin.close(fileDescriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(
                    fileDescriptor,
                    base.advanced(by: written),
                    buffer.count - written
                )
                guard result > 0 else {
                    throw HarcBackgroundBatchIngestError.rollbackIO(
                        operation: "write",
                        code: errno
                    )
                }
                written += result
            }
        }
        guard fsync(fileDescriptor) == 0 else {
            throw HarcBackgroundBatchIngestError.rollbackIO(
                operation: "fsync",
                code: errno
            )
        }
        return HarcBackgroundRollbackChunk(
            url: fileURL,
            descriptor: descriptor
        )
        #else
        throw HarcBackgroundBatchIngestError.invalidRollbackRoot
        #endif
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
