import CryptoKit
import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcTransfer

public struct HostBackgroundChunkBinding: Equatable, Hashable, Sendable {
    public let chunkIndex: UInt32
    public let encodedSHA256: EncodedChunkSHA256

    public init(chunkIndex: UInt32, encodedSHA256: EncodedChunkSHA256) {
        self.chunkIndex = chunkIndex
        self.encodedSHA256 = encodedSHA256
    }
}

public struct HostBackgroundCapabilityMintRequest: Equatable, Sendable {
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let uploadProfileSHA256: UploadProfileSHA256
    public let batchID: AudioBatchID
    public let chunks: [HostBackgroundChunkBinding]
    public let exactBatchBodySHA256: ImmutableBatchSHA256
    public let exactBatchBodyLength: UInt64
    public let requestedExpiresAt: Date

    public init(
        uploadID: UploadID,
        generation: UploadGeneration,
        uploadProfileSHA256: UploadProfileSHA256,
        batchID: AudioBatchID,
        chunks: [HostBackgroundChunkBinding],
        exactBatchBodySHA256: ImmutableBatchSHA256,
        exactBatchBodyLength: UInt64,
        requestedExpiresAt: Date
    ) throws {
        guard !chunks.isEmpty else {
            throw TransferValidationError.invalidLength(
                field: "HostBackgroundCapabilityMintRequest.chunks",
                value: 0
            )
        }
        guard chunks.count <= TransferLimits.backgroundBatchEntries else {
            throw TransferValidationError.exceedsLimit(
                field: "HostBackgroundCapabilityMintRequest.chunks",
                limit: UInt64(TransferLimits.backgroundBatchEntries),
                actual: UInt64(chunks.count)
            )
        }
        var priorIndex: UInt32?
        for chunk in chunks {
            if let priorIndex, chunk.chunkIndex <= priorIndex {
                throw TransferValidationError.invalidOrdering(
                    field: "HostBackgroundCapabilityMintRequest.chunks"
                )
            }
            priorIndex = chunk.chunkIndex
        }
        guard exactBatchBodyLength > 0 else {
            throw TransferValidationError.invalidLength(
                field: "HostBackgroundCapabilityMintRequest.exactBatchBodyLength",
                value: exactBatchBodyLength
            )
        }
        guard exactBatchBodyLength <= TransferLimits.backgroundBatchBytes else {
            throw TransferValidationError.exceedsLimit(
                field: "HostBackgroundCapabilityMintRequest.exactBatchBodyLength",
                limit: TransferLimits.backgroundBatchBytes,
                actual: exactBatchBodyLength
            )
        }
        guard requestedExpiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TransferValidationError.invalidDate(
                field: "HostBackgroundCapabilityMintRequest.requestedExpiresAt"
            )
        }

        self.uploadID = uploadID
        self.generation = generation
        self.uploadProfileSHA256 = uploadProfileSHA256
        self.batchID = batchID
        self.chunks = chunks
        self.exactBatchBodySHA256 = exactBatchBodySHA256
        self.exactBatchBodyLength = exactBatchBodyLength
        self.requestedExpiresAt = requestedExpiresAt
    }
}

public struct HostBackgroundCapabilityPolicy: Equatable, Sendable {
    public static let defaultMaximumLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let hardMaximumLifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let standard = try! HostBackgroundCapabilityPolicy()

    public let maximumLifetime: TimeInterval

    public init(maximumLifetime: TimeInterval = defaultMaximumLifetime) throws {
        guard maximumLifetime.isFinite,
              maximumLifetime > 0,
              maximumLifetime <= Self.hardMaximumLifetime else {
            throw TransferValidationError.invalidDate(
                field: "HostBackgroundCapabilityPolicy.maximumLifetime"
            )
        }
        self.maximumLifetime = maximumLifetime
    }
}

/// A serving-runtime snapshot taken only after the TLS retirement window for
/// `capabilityExpiresAt` has been reserved. Its URL is a reachability hint, not
/// an authority fact: the capability binds the path but not host, IP, or port.
public struct HostBackgroundCapabilityTransportSnapshot: Equatable, Sendable {
    public let absoluteUploadURL: URL
    public let currentTransportSetEpoch: UInt64
    public let exactSignedTransportSet: Data

    public init(
        absoluteUploadURL: URL,
        currentTransportSetEpoch: UInt64,
        exactSignedTransportSet: Data
    ) throws {
        guard currentTransportSetEpoch > 0 else {
            throw HarcHostError.transportSetNotInitialized
        }
        guard (1 ... 4_096).contains(exactSignedTransportSet.count) else {
            throw HarcHostError.invalidTransportSet(
                "The exact signed transport set has an invalid size."
            )
        }
        self.absoluteUploadURL = absoluteUploadURL
        self.currentTransportSetEpoch = currentTransportSetEpoch
        self.exactSignedTransportSet = exactSignedTransportSet
    }
}

public protocol HostBackgroundCapabilityTransportSnapshotProviding: Sendable {
    /// The implementation must reserve transport-key coverage through the
    /// supplied expiry and return the live no-redirect HTTPS listener URL.
    func reserveBackgroundCapabilityTransport(
        forHTTPPath httpPath: String,
        capabilityExpiresAt: Date
    ) async throws -> HostBackgroundCapabilityTransportSnapshot
}

public protocol HostBackgroundCapabilityRandomness: Sendable {
    func generateCapabilityID() throws -> UUID
    func generateSecret(byteCount: Int) throws -> Data
}

public struct SystemHostBackgroundCapabilityRandomness:
    HostBackgroundCapabilityRandomness,
    Sendable
{
    public init() {}

    public func generateCapabilityID() throws -> UUID {
        UUID()
    }

    public func generateSecret(byteCount: Int) throws -> Data {
        guard byteCount > 0 else {
            throw HarcHostError.invalidAuthenticationInput(
                "backgroundCapabilitySecretLength"
            )
        }
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< byteCount).map { _ in
            UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
        })
    }
}

public struct HostBackgroundCapabilityMintResult: Equatable, Sendable {
    public let capabilityID: UUID
    public let absoluteUploadURL: URL
    public let opaqueCapabilityCredential: Data
    public let issuedAt: Date
    public let expiresAt: Date
    public let byteCeiling: UInt64
    public let minimumTransportSetEpoch: UInt64
    public let exactSignedTransportSet: Data
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let batchID: AudioBatchID
    public let exactBatchBodySHA256: ImmutableBatchSHA256
    public let httpMethod: String
    public let httpPath: String
    public let expiryWasClamped: Bool
}

private struct PreparedBackgroundCapabilityCredential: Sendable {
    static let secretByteCount = 32
    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
    private static let bindingDomain = Data(
        "HARC-UPLOAD-CAPABILITY-V1\0".utf8
    )

    let capabilityID: UUID
    let exactBytes: Data
    let bindingSHA256: Data

    init(randomness: any HostBackgroundCapabilityRandomness) throws {
        let capabilityID = try randomness.generateCapabilityID()
        guard capabilityID != Self.zeroUUID else {
            throw HarcHostError.invalidAuthenticationInput(
                "backgroundCapabilityID"
            )
        }
        let secret = try randomness.generateSecret(
            byteCount: Self.secretByteCount
        )
        guard secret.count == Self.secretByteCount else {
            throw HarcHostError.invalidAuthenticationInput(
                "backgroundCapabilitySecretLength"
            )
        }

        var uuid = capabilityID.uuid
        var credential = withUnsafeBytes(of: &uuid) { Data($0) }
        credential.append(secret)
        guard credential.count == 48 else {
            throw HarcHostError.invalidAuthenticationInput(
                "backgroundCapabilityCredentialLength"
            )
        }
        var bindingInput = Self.bindingDomain
        bindingInput.append(credential)

        self.capabilityID = capabilityID
        exactBytes = credential
        bindingSHA256 = Data(SHA256.hash(data: bindingInput))
    }
}

extension HarcHostStore {
    public func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        request: HostBackgroundCapabilityMintRequest,
        transportSnapshotProvider: any HostBackgroundCapabilityTransportSnapshotProviding,
        policy: HostBackgroundCapabilityPolicy = .standard,
        randomness: any HostBackgroundCapabilityRandomness =
            SystemHostBackgroundCapabilityRandomness()
    ) async throws -> HostBackgroundCapabilityMintResult {
        try await mintBackgroundCapability(
            context: context,
            request: request,
            transportSnapshotProvider: transportSnapshotProvider,
            policy: policy,
            randomness: randomness,
            at: now()
        )
    }

    /// Deterministic `@testable` seam. The final authorization, immutable-batch
    /// replay decision, and both capability rows are still one transaction.
    func mintBackgroundCapability(
        context: AuthenticatedDeviceContext,
        request: HostBackgroundCapabilityMintRequest,
        transportSnapshotProvider: any HostBackgroundCapabilityTransportSnapshotProviding,
        policy: HostBackgroundCapabilityPolicy = .standard,
        randomness: any HostBackgroundCapabilityRandomness,
        at issuedAt: Date
    ) async throws -> HostBackgroundCapabilityMintResult {
        try await repairSecurityRegistryOnReopen()
        guard issuedAt.timeIntervalSinceReferenceDate.isFinite,
              request.requestedExpiresAt > issuedAt else {
            throw TransferValidationError.invalidDate(
                field: "HostBackgroundCapabilityMintRequest.requestedExpiresAt"
            )
        }

        // The lifecycle reservation is asynchronous and may update its own
        // conservative leaf-retirement floor. Compute a read-only candidate,
        // then repeat every authority check in the single effect transaction.
        let preflightExpiry = try await dbQueue.read { db in
            guard let attempt = try self.fetchUploadAttempt(
                in: db,
                uploadID: request.uploadID
            ) else {
                throw HarcHostError.uploadNotFound
            }
            try self.requireUploadProfile(
                request.uploadProfileSHA256,
                for: attempt
            )
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: issuedAt
            )
            try attempt.requireActive(
                generation: request.generation,
                at: issuedAt
            )
            return try self.backgroundCapabilityExpiry(
                request: request,
                attempt: attempt,
                grantExpiresAt: try self.currentGrantExpiry(
                    in: db,
                    deviceID: context.authenticatedDeviceID
                ),
                policy: policy,
                issuedAt: issuedAt
            )
        }

        let httpMethod = "PUT"
        let httpPath = Self.backgroundCapabilityHTTPPath(
            uploadID: request.uploadID,
            batchID: request.batchID
        )
        let transportSnapshot = try await transportSnapshotProvider
            .reserveBackgroundCapabilityTransport(
                forHTTPPath: httpPath,
                capabilityExpiresAt: preflightExpiry
            )
        try Self.validateBackgroundUploadURL(
            transportSnapshot.absoluteUploadURL,
            exactHTTPPath: httpPath
        )
        let credential = try PreparedBackgroundCapabilityCredential(
            randomness: randomness
        )

        let expiresAt: Date = try await dbQueue.write { db in
            guard let attempt = try self.fetchUploadAttempt(
                in: db,
                uploadID: request.uploadID
            ) else {
                throw HarcHostError.uploadNotFound
            }
            try self.requireUploadProfile(
                request.uploadProfileSHA256,
                for: attempt
            )
            _ = try self.authorizeInDatabase(
                db,
                context: context,
                requiredScope: .recordingUploadOwn,
                objectOwner: attempt.ownerDeviceID,
                at: issuedAt
            )
            try attempt.requireActive(
                generation: request.generation,
                at: issuedAt
            )

            let expiresAt = try self.backgroundCapabilityExpiry(
                request: request,
                attempt: attempt,
                grantExpiresAt: try self.currentGrantExpiry(
                    in: db,
                    deviceID: context.authenticatedDeviceID
                ),
                policy: policy,
                issuedAt: issuedAt
            )
            guard expiresAt <= preflightExpiry else {
                throw HarcHostError.transportRotationStateMismatch
            }

            let epoch = try Self.sqliteInteger(
                transportSnapshot.currentTransportSetEpoch,
                field: "minimumTransportSetEpoch"
            )
            guard try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_transport_set_publications"
            ) == 0,
            let transportRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT metadata.highest_transport_set_epoch,
                           metadata.exact_transport_set_bytes,
                           transport.exact_signed_bytes
                      FROM host_metadata AS metadata
                      JOIN host_transport_sets AS transport
                        ON transport.epoch = metadata.highest_transport_set_epoch
                     WHERE metadata.singleton = 1
                    """
            ), transportRow["highest_transport_set_epoch"] as Int64 == epoch,
               transportRow["exact_transport_set_bytes"] as Data?
                    == transportSnapshot.exactSignedTransportSet,
               transportRow["exact_signed_bytes"] as Data
                    == transportSnapshot.exactSignedTransportSet else {
                throw HarcHostError.transportSetTransitionInProgress
            }

            let declarations = Dictionary(
                uniqueKeysWithValues: attempt.declarations.descriptors.map {
                    ($0.chunkIndex, $0)
                }
            )
            let resolvedChunks = try request.chunks.map { requested in
                guard let declaration = declarations[requested.chunkIndex] else {
                    throw TransferValidationError.invalidUploadAttempt(
                        reason: "A background batch names an undeclared chunk."
                    )
                }
                guard declaration.encodedSHA256 == requested.encodedSHA256 else {
                    throw TransferValidationError.profileMismatch(
                        field: "backgroundChunk.encodedSHA256"
                    )
                }
                return declaration
            }
            let descriptor = try ImmutableAudioBatchDescriptor(
                batchID: request.batchID,
                uploadID: request.uploadID,
                generation: request.generation,
                uploadProfileSHA256: attempt.frozenProfile.profileSHA256,
                originRecordingID: attempt.originRecordingID,
                ownerDeviceID: attempt.ownerDeviceID,
                chunks: resolvedChunks,
                exactBodyByteLength: request.exactBatchBodyLength,
                exactBodySHA256: request.exactBatchBodySHA256
            )

            let generation = try Self.sqliteInteger(
                request.generation.rawValue,
                field: "uploadGeneration"
            )
            let bodyLength = try Self.sqliteInteger(
                request.exactBatchBodyLength,
                field: "exactBatchBodyLength"
            )
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM upload_batches WHERE batch_id = ?",
                arguments: [request.batchID.description]
            ) {
                let storedDescriptor = try Self.decode(
                    ImmutableAudioBatchDescriptor.self,
                    from: row["descriptor_json"] as Data
                )
                guard row["upload_id"] as String == request.uploadID.description,
                      row["owner_device_id"] as Data == attempt.ownerDeviceID.rawBytes,
                      row["generation"] as Int64 == generation,
                      row["body_sha256"] as Data
                        == request.exactBatchBodySHA256.rawBytes,
                      row["body_length"] as Int64 == bodyLength,
                      storedDescriptor == descriptor else {
                    throw HarcHostError.replayConflict
                }
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO upload_batches (
                            batch_id, upload_id, owner_device_id, generation,
                            descriptor_json, body_sha256, body_length,
                            exact_ack_bytes, state, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                        """,
                    arguments: [
                        request.batchID.description,
                        request.uploadID.description,
                        attempt.ownerDeviceID.rawBytes,
                        generation,
                        try Self.encode(descriptor),
                        request.exactBatchBodySHA256.rawBytes,
                        bodyLength,
                        "awaiting-upload",
                        Self.unixTime(issuedAt),
                        Self.unixTime(issuedAt),
                    ]
                )
            }

            let capabilityID = credential.capabilityID.uuidString.lowercased()
            try db.execute(
                sql: """
                    INSERT INTO background_capabilities (
                        capability_id, upload_id, batch_id, owner_device_id,
                        grant_id, grant_epoch, generation,
                        capability_binding_sha256, expires_at, invalidated_at,
                        state, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                    """,
                arguments: [
                    capabilityID,
                    request.uploadID.description,
                    request.batchID.description,
                    attempt.ownerDeviceID.rawBytes,
                    context.grantID.description,
                    try Self.sqliteInteger(
                        context.grantEpoch.rawValue,
                        field: "grantEpoch"
                    ),
                    generation,
                    credential.bindingSHA256,
                    Self.unixTime(expiresAt),
                    "issued",
                    Self.unixTime(issuedAt),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO background_capability_bindings (
                        capability_id, binding_version, library_id,
                        host_authority_id, minimum_transport_set_epoch,
                        http_method, http_path, exact_body_sha256,
                        exact_body_length, byte_ceiling, issued_at, expires_at
                    ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    capabilityID,
                    self.expectedMetadata.libraryID.description,
                    self.expectedMetadata.hostAuthorityID.rawBytes,
                    epoch,
                    httpMethod,
                    httpPath,
                    request.exactBatchBodySHA256.rawBytes,
                    bodyLength,
                    bodyLength,
                    Self.unixTime(issuedAt),
                    Self.unixTime(expiresAt),
                ]
            )
            return expiresAt
        }

        return HostBackgroundCapabilityMintResult(
            capabilityID: credential.capabilityID,
            absoluteUploadURL: transportSnapshot.absoluteUploadURL,
            opaqueCapabilityCredential: credential.exactBytes,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            byteCeiling: request.exactBatchBodyLength,
            minimumTransportSetEpoch:
                transportSnapshot.currentTransportSetEpoch,
            exactSignedTransportSet: transportSnapshot.exactSignedTransportSet,
            uploadID: request.uploadID,
            generation: request.generation,
            batchID: request.batchID,
            exactBatchBodySHA256: request.exactBatchBodySHA256,
            httpMethod: httpMethod,
            httpPath: httpPath,
            expiryWasClamped: expiresAt < request.requestedExpiresAt
        )
    }

    private nonisolated func backgroundCapabilityExpiry(
        request: HostBackgroundCapabilityMintRequest,
        attempt: UploadAttempt,
        grantExpiresAt: Date?,
        policy: HostBackgroundCapabilityPolicy,
        issuedAt: Date
    ) throws -> Date {
        let policyExpiry = issuedAt.addingTimeInterval(policy.maximumLifetime)
        guard policyExpiry.timeIntervalSinceReferenceDate.isFinite else {
            throw TransferValidationError.invalidDate(
                field: "HostBackgroundCapabilityPolicy.maximumLifetime"
            )
        }
        var candidates = [
            request.requestedExpiresAt,
            policyExpiry,
            attempt.generationExpiresAt,
        ]
        if let grantExpiresAt {
            candidates.append(grantExpiresAt)
        }
        guard let expiry = candidates.min(), expiry > issuedAt else {
            throw TransferValidationError.invalidDate(
                field: "HostBackgroundCapabilityMintResult.expiresAt"
            )
        }
        return expiry
    }

    private nonisolated static func backgroundCapabilityHTTPPath(
        uploadID: UploadID,
        batchID: AudioBatchID
    ) -> String {
        "/v1/uploads/\(uploadID.description)/batches/\(batchID.description)"
    }

    private nonisolated static func validateBackgroundUploadURL(
        _ url: URL,
        exactHTTPPath: String
    ) throws {
        guard url.baseURL == nil,
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              components.scheme == "https",
              let host = components.host?.lowercased(),
              host.hasSuffix(".local"),
              !host.contains(":"),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == exactHTTPPath,
              components.path == exactHTTPPath else {
            throw HarcHostError.invalidAuthenticationInput(
                "backgroundCapabilityUploadURL"
            )
        }
    }
}
