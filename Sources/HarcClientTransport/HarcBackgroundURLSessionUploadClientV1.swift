#if canImport(Network)
import CryptoKit
@preconcurrency import Foundation
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

public enum HarcBackgroundURLSessionUploadError:
    Error, Equatable, Sendable
{
    case invalidEndpointBinding(field: String)
    case corruptEndpointBinding
    case capabilityExpired
    case bodyUnavailable
    case bodyIntegrityMismatch
    case sessionNotInstalled
    case taskIdentityMismatch
    case missingTaskMapping
    case missingBackgroundBatch
    case invalidPersistedRequest
    case transportFailed(domain: String, code: Int)
    case responseTooLarge
    case serverRejected(statusCode: Int)
    case invalidHTTPResponse(field: String)
    case acknowledgementValidationFailed
    case duplicateBackgroundCompletionHandler
    case wrongBackgroundSessionIdentifier
}

/// Canonical, locally durable reconstruction of the request-bound portion of
/// a validated, session-authenticated background capability response. Its
/// signed transport-set evidence is persisted separately, while these exact
/// bytes live in the transfer
/// store's opaque capability-binding slot beside the credential and body.
public struct HarcBackgroundUploadEndpointBindingV1: Equatable, Sendable {
    public static let version = 1

    public let absoluteUploadURL: URL
    public let httpMethod: String
    public let httpPath: String
    public let uploadID: UploadID
    public let generation: UploadGeneration
    public let batchID: AudioBatchID
    public let exactBodyByteLength: UInt64
    public let exactBodySHA256: ImmutableBatchSHA256
    public let byteCeiling: UInt64
    public let minimumTransportSetEpoch: UInt64
    public let trustTuple: AdoptedTrustTuple
    public let credentialSHA256: Data
    public let expiresAt: Date

    public init(
        capability: HarcValidatedMintBackgroundCapabilityResponseV1,
        batch: ImmutableAudioBatchDescriptor,
        hostTrust: RecordingHostTrustBinding
    ) throws {
        guard capability.uploadID == batch.uploadID else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "uploadID")
        }
        guard capability.generation == batch.generation else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "generation")
        }
        guard capability.batchID == batch.batchID else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "batchID")
        }
        guard capability.exactBatchBodySHA256
                == batch.exactBodySHA256 else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "exactBodySHA256")
        }
        guard capability.byteCeiling == batch.exactBodyByteLength else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "exactBodyByteLength")
        }
        let transportSet = capability.exactTransportSet.transportSet
        guard transportSet.libraryID == hostTrust.libraryID,
              transportSet.hostAuthorityID == hostTrust.hostAuthorityID,
              transportSet.setEpoch
                >= capability.minimumTransportSetEpoch else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "transportSet")
        }

        try self.init(
            absoluteUploadURL: capability.absoluteUploadURL,
            httpMethod: capability.httpMethod,
            httpPath: capability.httpPath,
            uploadID: batch.uploadID,
            generation: batch.generation,
            batchID: batch.batchID,
            exactBodyByteLength: batch.exactBodyByteLength,
            exactBodySHA256: batch.exactBodySHA256,
            byteCeiling: capability.byteCeiling,
            minimumTransportSetEpoch:
                capability.minimumTransportSetEpoch,
            trustTuple: AdoptedTrustTuple(
                libraryID: hostTrust.libraryID,
                hostAuthorityID: hostTrust.hostAuthorityID
            ),
            credentialSHA256: Data(
                SHA256.hash(
                    data: capability.opaqueCapabilityCredential
                )
            ),
            expiresAt: capability.expiresAt
        )
    }

    init(
        absoluteUploadURL: URL,
        httpMethod: String,
        httpPath: String,
        uploadID: UploadID,
        generation: UploadGeneration,
        batchID: AudioBatchID,
        exactBodyByteLength: UInt64,
        exactBodySHA256: ImmutableBatchSHA256,
        byteCeiling: UInt64,
        minimumTransportSetEpoch: UInt64,
        trustTuple: AdoptedTrustTuple,
        credentialSHA256: Data,
        expiresAt: Date
    ) throws {
        let expectedPath = "/v1/uploads/\(uploadID)/batches/\(batchID)"
        guard let components = URLComponents(
            url: absoluteUploadURL,
            resolvingAgainstBaseURL: false
        ), components.scheme == "https",
           components.host?.isEmpty == false,
           components.user == nil,
           components.password == nil,
           components.query == nil,
           components.fragment == nil,
           components.percentEncodedPath == httpPath,
           httpPath == expectedPath else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "absoluteUploadURL")
        }
        guard httpMethod == "PUT" else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "httpMethod")
        }
        guard exactBodyByteLength > 0,
              exactBodyByteLength == byteCeiling,
              byteCeiling <= TransferLimits.backgroundBatchBytes else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "byteCeiling")
        }
        guard minimumTransportSetEpoch > 0 else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(
                    field: "minimumTransportSetEpoch"
                )
        }
        guard credentialSHA256.count == SHA256.Digest.byteCount else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "credentialSHA256")
        }
        guard expiresAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970 > 0 else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "expiresAt")
        }

        self.absoluteUploadURL = absoluteUploadURL
        self.httpMethod = httpMethod
        self.httpPath = httpPath
        self.uploadID = uploadID
        self.generation = generation
        self.batchID = batchID
        self.exactBodyByteLength = exactBodyByteLength
        self.exactBodySHA256 = exactBodySHA256
        self.byteCeiling = byteCeiling
        self.minimumTransportSetEpoch = minimumTransportSetEpoch
        self.trustTuple = trustTuple
        self.credentialSHA256 = credentialSHA256
        self.expiresAt = expiresAt
    }

    public func exactBytes() throws -> Data {
        let wire = Wire(
            version: Self.version,
            absoluteUploadURL: absoluteUploadURL.absoluteString,
            httpMethod: httpMethod,
            httpPath: httpPath,
            uploadID: uploadID.description,
            generation: generation.rawValue,
            batchID: batchID.description,
            exactBodyByteLength: exactBodyByteLength,
            exactBodySHA256: exactBodySHA256.rawBytes,
            byteCeiling: byteCeiling,
            minimumTransportSetEpoch: minimumTransportSetEpoch,
            libraryID: trustTuple.libraryID.description,
            hostAuthorityID: trustTuple.hostAuthorityID.rawBytes,
            credentialSHA256: credentialSHA256,
            expiresAtUnixMilliseconds: try Self.unixMilliseconds(
                expiresAt
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(wire)
    }

    public init(exactBytes: Data) throws {
        guard !exactBytes.isEmpty, exactBytes.count <= 16 * 1_024 else {
            throw HarcBackgroundURLSessionUploadError.corruptEndpointBinding
        }
        do {
            let decoder = JSONDecoder()
            let wire = try decoder.decode(Wire.self, from: exactBytes)
            guard wire.version == Self.version,
                  let absoluteURL = URL(string: wire.absoluteUploadURL),
                  absoluteURL.absoluteString == wire.absoluteUploadURL,
                  let uploadUUID = UUID(uuidString: wire.uploadID),
                  uploadUUID.uuidString.lowercased() == wire.uploadID,
                  let batchUUID = UUID(uuidString: wire.batchID),
                  batchUUID.uuidString.lowercased() == wire.batchID,
                  let libraryUUID = UUID(uuidString: wire.libraryID),
                  libraryUUID.uuidString.lowercased() == wire.libraryID
            else {
                throw HarcBackgroundURLSessionUploadError
                    .corruptEndpointBinding
            }
            try self.init(
                absoluteUploadURL: absoluteURL,
                httpMethod: wire.httpMethod,
                httpPath: wire.httpPath,
                uploadID: UploadID(uploadUUID),
                generation: UploadGeneration(wire.generation),
                batchID: AudioBatchID(batchUUID),
                exactBodyByteLength: wire.exactBodyByteLength,
                exactBodySHA256: ImmutableBatchSHA256(
                    wire.exactBodySHA256
                ),
                byteCeiling: wire.byteCeiling,
                minimumTransportSetEpoch:
                    wire.minimumTransportSetEpoch,
                trustTuple: AdoptedTrustTuple(
                    libraryID: LibraryID(libraryUUID),
                    hostAuthorityID: try HostAuthorityID(
                        wire.hostAuthorityID
                    )
                ),
                credentialSHA256: wire.credentialSHA256,
                expiresAt: try Self.date(
                    unixMilliseconds: wire.expiresAtUnixMilliseconds
                )
            )
            guard exactBytes == (try self.exactBytes()) else {
                throw HarcBackgroundURLSessionUploadError
                    .corruptEndpointBinding
            }
        } catch {
            if let bindingError = error as?
                HarcBackgroundURLSessionUploadError {
                throw bindingError
            }
            throw HarcBackgroundURLSessionUploadError.corruptEndpointBinding
        }
    }

    func validate(
        batch: ImmutableAudioBatchDescriptor,
        capability: OpaqueBackgroundCapability
    ) throws {
        guard batch.uploadID == uploadID,
              batch.generation == generation,
              batch.batchID == batchID,
              batch.exactBodyByteLength == exactBodyByteLength,
              batch.exactBodySHA256 == exactBodySHA256,
              capability.expiresAt == expiresAt,
              Data(SHA256.hash(data: capability.credential))
                == credentialSHA256 else {
            throw HarcBackgroundURLSessionUploadError
                .corruptEndpointBinding
        }
    }

    private struct Wire: Codable, Equatable {
        let version: Int
        let absoluteUploadURL: String
        let httpMethod: String
        let httpPath: String
        let uploadID: String
        let generation: UInt64
        let batchID: String
        let exactBodyByteLength: UInt64
        let exactBodySHA256: Data
        let byteCeiling: UInt64
        let minimumTransportSetEpoch: UInt64
        let libraryID: String
        let hostAuthorityID: Data
        let credentialSHA256: Data
        let expiresAtUnixMilliseconds: Int64
    }

    private static func unixMilliseconds(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds.rounded() == milliseconds,
              let value = Int64(exactly: milliseconds) else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "expiresAt")
        }
        return value
    }

    private static func date(unixMilliseconds value: Int64) throws -> Date {
        guard value > 0 else {
            throw HarcBackgroundURLSessionUploadError
                .corruptEndpointBinding
        }
        let date = Date(
            timeIntervalSince1970: Double(value) / 1_000
        )
        guard try unixMilliseconds(date) == value else {
            throw HarcBackgroundURLSessionUploadError
                .corruptEndpointBinding
        }
        return date
    }
}

public struct HarcBackgroundUploadSchedulingPlanV1: Sendable {
    public let descriptor: ImmutableAudioBatchDescriptor
    public let bodyFileURL: URL
    public let capability: OpaqueBackgroundCapability
    public let endpointBinding: HarcBackgroundUploadEndpointBindingV1

    let transportSetEvidence: ValidatedTransportSetEvidence

    public init(
        descriptor: ImmutableAudioBatchDescriptor,
        bodyFileURL: URL,
        capabilityResponse:
            HarcValidatedMintBackgroundCapabilityResponseV1,
        hostTrust: RecordingHostTrustBinding
    ) throws {
        guard bodyFileURL.isFileURL,
              bodyFileURL.standardizedFileURL.path == bodyFileURL.path else {
            throw HarcBackgroundURLSessionUploadError.bodyUnavailable
        }
        let verifiedTransportSet = try VerifiedHostTransportSetV1.decode(
            capabilityResponse.exactTransportSet.exactBytes,
            hostAuthorityPublicKey: hostTrust.hostAuthorityPublicKey
        )
        guard verifiedTransportSet.transportSet.libraryID
                == hostTrust.libraryID,
              verifiedTransportSet.transportSet.hostAuthorityID
                == hostTrust.hostAuthorityID,
              verifiedTransportSet.transportSet.setEpoch
                >= capabilityResponse.minimumTransportSetEpoch else {
            throw HarcBackgroundURLSessionUploadError
                .invalidEndpointBinding(field: "transportSet")
        }
        let binding = try HarcBackgroundUploadEndpointBindingV1(
            capability: capabilityResponse,
            batch: descriptor,
            hostTrust: hostTrust
        )
        let capability = try OpaqueBackgroundCapability(
            credential: capabilityResponse.opaqueCapabilityCredential,
            capabilityBindings: binding.exactBytes(),
            expiresAt: capabilityResponse.expiresAt
        )
        self.descriptor = descriptor
        self.bodyFileURL = bodyFileURL
        self.capability = capability
        self.endpointBinding = binding
        self.transportSetEvidence = try verifiedTransportSet
            .validatedEvidence()
    }

    init(
        descriptor: ImmutableAudioBatchDescriptor,
        bodyFileURL: URL,
        capability: OpaqueBackgroundCapability,
        endpointBinding: HarcBackgroundUploadEndpointBindingV1,
        transportSetEvidence: ValidatedTransportSetEvidence
    ) throws {
        try endpointBinding.validate(
            batch: descriptor,
            capability: capability
        )
        self.descriptor = descriptor
        self.bodyFileURL = bodyFileURL
        self.capability = capability
        self.endpointBinding = endpointBinding
        self.transportSetEvidence = transportSetEvidence
    }
}

struct HarcBackgroundUploadJobV1: Sendable {
    let descriptor: ImmutableAudioBatchDescriptor
    let bodyFileURL: URL
    let capability: OpaqueBackgroundCapability
    let endpointBinding: HarcBackgroundUploadEndpointBindingV1

    init(
        descriptor: ImmutableAudioBatchDescriptor,
        bodyFileURL: URL,
        capability: OpaqueBackgroundCapability,
        endpointBinding: HarcBackgroundUploadEndpointBindingV1
    ) throws {
        guard bodyFileURL.isFileURL else {
            throw HarcBackgroundURLSessionUploadError.bodyUnavailable
        }
        try endpointBinding.validate(
            batch: descriptor,
            capability: capability
        )
        self.descriptor = descriptor
        self.bodyFileURL = bodyFileURL.standardizedFileURL
        self.capability = capability
        self.endpointBinding = endpointBinding
    }
}

protocol HarcBackgroundUploadPersistenceV1: Sendable {
    func persistTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) throws
    func persistJob(_ job: HarcBackgroundUploadJobV1) throws
    func job(batchID: AudioBatchID) throws -> HarcBackgroundUploadJobV1?
    func persistTaskMappingBeforeResume(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID
    ) throws
    func taskMappings() throws -> [StoredBackgroundTaskMapping]
    func reconcileTasks(
        _ observed: Set<SystemBackgroundTaskIdentity>
    ) throws -> BackgroundTaskReconciliation
    func activeHostTrust(
        for tuple: AdoptedTrustTuple
    ) throws -> RecordingHostTrustBinding
    func persistAcknowledgement(
        _ evidence: ValidatedBatchAcknowledgementEvidence
    ) throws
    func persistTaskFailure(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID,
        disposition: BackgroundTaskFailureDisposition
    ) throws
}

final class HarcTransferStoreBackgroundUploadPersistenceV1:
    HarcBackgroundUploadPersistenceV1, @unchecked Sendable
{
    private let store: HarcTransferStore

    init(store: HarcTransferStore) { self.store = store }

    func persistTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) throws {
        _ = try store.persistVerifiedTransportSet(evidence)
    }

    func persistJob(_ job: HarcBackgroundUploadJobV1) throws {
        try store.persistBackgroundBatchForScheduling(
            job.descriptor,
            bodyFileURL: job.bodyFileURL,
            capability: job.capability
        )
    }

    func job(
        batchID: AudioBatchID
    ) throws -> HarcBackgroundUploadJobV1? {
        guard let stored = try store.backgroundBatch(id: batchID) else {
            return nil
        }
        guard stored.bodyFileState == .present else {
            throw HarcBackgroundURLSessionUploadError.bodyUnavailable
        }
        let binding = try HarcBackgroundUploadEndpointBindingV1(
            exactBytes: stored.capability.capabilityBindings
        )
        return try HarcBackgroundUploadJobV1(
            descriptor: stored.descriptor,
            bodyFileURL: stored.bodyFileURL,
            capability: stored.capability,
            endpointBinding: binding
        )
    }

    func persistTaskMappingBeforeResume(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID
    ) throws {
        try store.persistTaskMappingBeforeResume(
            identity,
            batchID: batchID
        )
    }

    func taskMappings() throws -> [StoredBackgroundTaskMapping] {
        try store.taskMappings()
    }

    func reconcileTasks(
        _ observed: Set<SystemBackgroundTaskIdentity>
    ) throws -> BackgroundTaskReconciliation {
        try store.reconcileBackgroundTasks(
            observedSystemTasks: observed
        )
    }

    func activeHostTrust(
        for tuple: AdoptedTrustTuple
    ) throws -> RecordingHostTrustBinding {
        let adoption = try store.authorizingAdoption(
            for: tuple,
            requiredScope: .recordingUploadOwn
        )
        return try RecordingHostTrustBinding(
            libraryID: adoption.tuple.libraryID,
            hostAuthorityID: adoption.tuple.hostAuthorityID,
            hostAuthorityPublicKeyX963:
                adoption.authorityPublicKeyX963
        )
    }

    func persistAcknowledgement(
        _ evidence: ValidatedBatchAcknowledgementEvidence
    ) throws {
        try store.persistVerifiedBatchACK(evidence)
    }

    func persistTaskFailure(
        _ identity: SystemBackgroundTaskIdentity,
        batchID: AudioBatchID,
        disposition: BackgroundTaskFailureDisposition
    ) throws {
        try store.persistBackgroundTaskFailure(
            identity,
            batchID: batchID,
            disposition: disposition
        )
    }
}

/// Bridges the synchronous transfer store into the shared async TLS trust
/// coordinator without making HarcClientStore depend on HarcClientTransport.
public struct HarcTransferStoreTransportTrustPersistenceV1:
    HarcTransportTrustPersistence, Sendable
{
    private let store: HarcTransferStore

    public init(store: HarcTransferStore) { self.store = store }

    public func loadActiveTransportTrust() async throws
        -> HarcPersistedTransportTrustState? {
        guard let adoption = try store.activeAdoption() else { return nil }
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: adoption.tuple.libraryID,
            hostAuthorityID: adoption.tuple.hostAuthorityID,
            hostAuthorityPublicKeyX963:
                adoption.authorityPublicKeyX963
        )
        return HarcPersistedTransportTrustState(
            hostTrust: hostTrust,
            highestTransportSetEpoch: adoption.transportSet.epoch,
            exactHighestTransportSet:
                adoption.transportSet.exactSignedBytes
        )
    }

    public func persistVerifiedTransportSet(
        _ evidence: ValidatedTransportSetEvidence
    ) async throws {
        _ = try store.persistVerifiedTransportSet(evidence)
    }
}

enum HarcBackgroundSystemTaskStateV1: Equatable, Sendable {
    case running
    case suspended
    case canceling
    case completed
}

protocol HarcBackgroundUploadSystemTaskV1: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var taskDescription: String? { get set }
    var originalRequest: URLRequest? { get }
    var state: HarcBackgroundSystemTaskStateV1 { get }
    func resume()
    func cancel()
}

protocol HarcBackgroundUploadSessionV1: Sendable {
    func makeUploadTask(
        request: URLRequest,
        bodyFileURL: URL
    ) throws -> any HarcBackgroundUploadSystemTaskV1
    func allTasks() async throws
        -> [any HarcBackgroundUploadSystemTaskV1]
}

private final class HarcFoundationBackgroundUploadTaskV1:
    HarcBackgroundUploadSystemTaskV1, @unchecked Sendable
{
    let task: URLSessionTask

    init(_ task: URLSessionTask) { self.task = task }

    var taskIdentifier: Int { task.taskIdentifier }
    var taskDescription: String? {
        get { task.taskDescription }
        set { task.taskDescription = newValue }
    }
    var originalRequest: URLRequest? { task.originalRequest }
    var state: HarcBackgroundSystemTaskStateV1 {
        switch task.state {
        case .running: .running
        case .suspended: .suspended
        case .canceling: .canceling
        case .completed: .completed
        @unknown default: .canceling
        }
    }
    func resume() { task.resume() }
    func cancel() { task.cancel() }
}

private final class HarcFoundationBackgroundUploadSessionV1:
    HarcBackgroundUploadSessionV1, @unchecked Sendable
{
    let session: URLSession

    init(session: URLSession) { self.session = session }

    func makeUploadTask(
        request: URLRequest,
        bodyFileURL: URL
    ) throws -> any HarcBackgroundUploadSystemTaskV1 {
        HarcFoundationBackgroundUploadTaskV1(
            session.uploadTask(with: request, fromFile: bodyFileURL)
        )
    }

    func allTasks() async throws
        -> [any HarcBackgroundUploadSystemTaskV1] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(
                    returning: tasks.map(
                        HarcFoundationBackgroundUploadTaskV1.init
                    )
                )
            }
        }
    }
}

private final class HarcBackgroundUploadSessionBoxV1:
    HarcBackgroundUploadSessionV1, @unchecked Sendable
{
    private let lock = NSLock()
    private var session: (any HarcBackgroundUploadSessionV1)?

    func install(_ session: any HarcBackgroundUploadSessionV1) {
        lock.lock()
        defer { lock.unlock() }
        precondition(self.session == nil)
        self.session = session
    }

    func makeUploadTask(
        request: URLRequest,
        bodyFileURL: URL
    ) throws -> any HarcBackgroundUploadSystemTaskV1 {
        guard let session = installedSession() else {
            throw HarcBackgroundURLSessionUploadError.sessionNotInstalled
        }
        return try session.makeUploadTask(
            request: request,
            bodyFileURL: bodyFileURL
        )
    }

    func allTasks() async throws
        -> [any HarcBackgroundUploadSystemTaskV1] {
        guard let session = installedSession() else {
            throw HarcBackgroundURLSessionUploadError.sessionNotInstalled
        }
        return try await session.allTasks()
    }

    private func installedSession()
        -> (any HarcBackgroundUploadSessionV1)? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}

enum HarcBackgroundUploadHTTPRequestV1 {
    static let requestContentType =
        "application/vnd.harc.audio-batch.v1"
    static let acknowledgementContentType =
        "application/vnd.harc.batch-ack.v1"
    static let maximumAcknowledgementBytes = 1 * 1_024 * 1_024

    static func makeRequest(
        for job: HarcBackgroundUploadJobV1
    ) throws -> URLRequest {
        try job.endpointBinding.validate(
            batch: job.descriptor,
            capability: job.capability
        )
        var request = URLRequest(
            url: job.endpointBinding.absoluteUploadURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 120
        )
        request.httpMethod = "PUT"
        request.setValue(
            "HarcUpload " + base64URL(job.capability.credential),
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            requestContentType,
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            acknowledgementContentType,
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            String(job.descriptor.exactBodyByteLength),
            forHTTPHeaderField: "Content-Length"
        )
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    static func matchesPersistedRequest(
        _ request: URLRequest?,
        job: HarcBackgroundUploadJobV1
    ) -> Bool {
        guard let request,
              request.url?.absoluteString
                == job.endpointBinding.absoluteUploadURL.absoluteString,
              request.httpMethod == "PUT",
              header("Authorization", in: request)
                == "HarcUpload "
                    + base64URL(job.capability.credential),
              header("Content-Type", in: request) == requestContentType,
              header("Accept", in: request)
                == acknowledgementContentType,
              header("Content-Length", in: request)
                == String(job.descriptor.exactBodyByteLength),
              header("Cache-Control", in: request) == "no-store",
              header("Content-Encoding", in: request) == nil,
              header("Transfer-Encoding", in: request) == nil else {
            return false
        }
        return true
    }

    static func taskDescription(batchID: AudioBatchID) -> String {
        "harc-background-batch:\(batchID)"
    }

    private static func header(
        _ name: String,
        in request: URLRequest
    ) -> String? {
        request.allHTTPHeaderFields?.first(where: {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        })?.value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct HarcBackgroundUploadHTTPResponseV1: Sendable {
    let url: URL?
    let statusCode: Int?
    let contentType: String?
    let contentLength: String?
    let cacheControl: String?
    let contentEncoding: String?

    init(_ response: URLResponse?) {
        guard let response = response as? HTTPURLResponse else {
            url = response?.url
            statusCode = nil
            contentType = nil
            contentLength = nil
            cacheControl = nil
            contentEncoding = nil
            return
        }
        url = response.url
        statusCode = response.statusCode
        contentType = response.value(forHTTPHeaderField: "Content-Type")
        contentLength = response.value(forHTTPHeaderField: "Content-Length")
        cacheControl = response.value(forHTTPHeaderField: "Cache-Control")
        contentEncoding = response.value(
            forHTTPHeaderField: "Content-Encoding"
        )
    }
}

struct HarcBackgroundUploadCompletionEventV1: Sendable {
    let taskIdentifier: Int
    let taskDescription: String?
    let originalRequest: URLRequest?
    let response: HarcBackgroundUploadHTTPResponseV1
    let responseBody: Data
    let responseOverflowed: Bool
    let transportFailure: HarcBackgroundURLSessionUploadError?
}

public struct HarcBackgroundUploadRelaunchResultV1: Equatable, Sendable {
    public let storeReconciliation: BackgroundTaskReconciliation
    public let newlyScheduledTasks: [SystemBackgroundTaskIdentity]
    public let batchesRequiringCapabilityRefresh: [AudioBatchID]

    public init(
        storeReconciliation: BackgroundTaskReconciliation,
        newlyScheduledTasks: [SystemBackgroundTaskIdentity],
        batchesRequiringCapabilityRefresh: [AudioBatchID]
    ) {
        self.storeReconciliation = storeReconciliation
        self.newlyScheduledTasks = newlyScheduledTasks
        self.batchesRequiringCapabilityRefresh =
            batchesRequiringCapabilityRefresh
    }
}

actor HarcBackgroundUploadCoordinatorV1 {
    typealias BodyVerifier = @Sendable (
        HarcBackgroundUploadJobV1
    ) throws -> Void

    private let persistence: any HarcBackgroundUploadPersistenceV1
    private let session: any HarcBackgroundUploadSessionV1
    private let acknowledgementValidator:
        any BatchAcknowledgementEvidenceValidating
    private let verifyBody: BodyVerifier
    private let now: @Sendable () -> Date

    init(
        persistence: any HarcBackgroundUploadPersistenceV1,
        session: any HarcBackgroundUploadSessionV1,
        acknowledgementValidator:
            any BatchAcknowledgementEvidenceValidating =
                HarcBatchAcknowledgementCodecV1(),
        verifyBody: @escaping BodyVerifier =
            HarcBackgroundUploadCoordinatorV1.verifyHARCAB1Body,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.session = session
        self.acknowledgementValidator = acknowledgementValidator
        self.verifyBody = verifyBody
        self.now = now
    }

    func schedule(
        _ plan: HarcBackgroundUploadSchedulingPlanV1
    ) throws -> SystemBackgroundTaskIdentity {
        guard plan.capability.expiresAt > now() else {
            throw HarcBackgroundURLSessionUploadError.capabilityExpired
        }
        let job = try HarcBackgroundUploadJobV1(
            descriptor: plan.descriptor,
            bodyFileURL: plan.bodyFileURL,
            capability: plan.capability,
            endpointBinding: plan.endpointBinding
        )
        try verifyBody(job)

        // Both security state and all task reconstruction facts are durable
        // before a resumable system task can exist.
        try persistence.persistTransportSet(plan.transportSetEvidence)
        try persistence.persistJob(job)
        return try createMappedTaskAndResume(job)
    }

    func reconcileAfterRelaunch() async throws
        -> HarcBackgroundUploadRelaunchResultV1 {
        let tasks = try await session.allTasks()
        let mappings = try persistence.taskMappings()
        let mappingsByIdentity = Dictionary(
            uniqueKeysWithValues: mappings.map { ($0.identity, $0) }
        )
        var validObserved = Set<SystemBackgroundTaskIdentity>()
        var validTasks: [
            SystemBackgroundTaskIdentity:
                any HarcBackgroundUploadSystemTaskV1
        ] = [:]

        for task in tasks {
            let identity: SystemBackgroundTaskIdentity
            do {
                identity = try SystemBackgroundTaskIdentity(
                    taskIdentifier: task.taskIdentifier
                )
            } catch {
                task.cancel()
                continue
            }
            guard task.state == .running || task.state == .suspended,
                  let mapping = mappingsByIdentity[identity],
                  mapping.state != .completed,
                  mapping.state != .securityBlocked,
                  let job = try persistence.job(
                      batchID: mapping.batchID
                  ),
                  task.taskDescription
                    == HarcBackgroundUploadHTTPRequestV1
                        .taskDescription(batchID: mapping.batchID),
                  HarcBackgroundUploadHTTPRequestV1
                    .matchesPersistedRequest(
                        task.originalRequest,
                        job: job
                    ),
                  job.capability.expiresAt > now() else {
                task.cancel()
                continue
            }
            validObserved.insert(identity)
            validTasks[identity] = task
        }

        let reconciliation = try persistence.reconcileTasks(validObserved)
        for identity in reconciliation.orphanedSystemTasks {
            tasks.first(where: {
                $0.taskIdentifier == identity.taskIdentifier
            })?.cancel()
        }
        for identity in reconciliation.matchedTasks {
            if validTasks[identity]?.state == .suspended {
                validTasks[identity]?.resume()
            }
        }

        var scheduled: [SystemBackgroundTaskIdentity] = []
        var requiresRefresh: [AudioBatchID] = []
        for batchID in reconciliation.batchesToReschedule {
            guard let job = try persistence.job(batchID: batchID) else {
                throw HarcBackgroundURLSessionUploadError
                    .missingBackgroundBatch
            }
            guard job.capability.expiresAt > now() else {
                requiresRefresh.append(batchID)
                continue
            }
            try verifyBody(job)
            scheduled.append(try createMappedTaskAndResume(job))
        }

        return HarcBackgroundUploadRelaunchResultV1(
            storeReconciliation: reconciliation,
            newlyScheduledTasks: scheduled,
            batchesRequiringCapabilityRefresh: requiresRefresh.sorted()
        )
    }

    @discardableResult
    func handleCompletion(
        _ event: HarcBackgroundUploadCompletionEventV1
    ) throws -> AudioBatchID {
        let identity = try SystemBackgroundTaskIdentity(
            taskIdentifier: event.taskIdentifier
        )
        guard let mapping = try persistence.taskMappings().first(
            where: { $0.identity == identity }
        ) else {
            throw HarcBackgroundURLSessionUploadError.missingTaskMapping
        }
        do {
            guard let job = try persistence.job(
                batchID: mapping.batchID
            ) else {
                throw HarcBackgroundURLSessionUploadError
                    .missingBackgroundBatch
            }
            guard event.taskDescription
                    == HarcBackgroundUploadHTTPRequestV1.taskDescription(
                        batchID: mapping.batchID
                    ),
                  HarcBackgroundUploadHTTPRequestV1.matchesPersistedRequest(
                      event.originalRequest,
                      job: job
                  ) else {
                throw HarcBackgroundURLSessionUploadError
                    .invalidPersistedRequest
            }
            if let failure = event.transportFailure { throw failure }
            guard !event.responseOverflowed else {
                throw HarcBackgroundURLSessionUploadError.responseTooLarge
            }
            try validateHTTPResponse(event, job: job)

            let hostTrust: RecordingHostTrustBinding
            do {
                hostTrust = try persistence.activeHostTrust(
                    for: job.endpointBinding.trustTuple
                )
            } catch {
                throw HarcBackgroundURLSessionUploadError
                    .acknowledgementValidationFailed
            }
            let evidence: ValidatedBatchAcknowledgementEvidence
            do {
                evidence = try acknowledgementValidator
                    .validateBatchAcknowledgement(
                        exactSignedAcknowledgementBytes:
                            event.responseBody,
                        batch: job.descriptor,
                        hostTrust: hostTrust
                    )
            } catch {
                throw HarcBackgroundURLSessionUploadError
                    .acknowledgementValidationFailed
            }
            // There is deliberately no cancellation point between validation
            // and this synchronous durable ACK + task-mapping boundary.
            try persistence.persistAcknowledgement(evidence)
            return mapping.batchID
        } catch {
            try persistence.persistTaskFailure(
                identity,
                batchID: mapping.batchID,
                disposition: Self.failureDisposition(for: error)
            )
            throw error
        }
    }

    private static func failureDisposition(
        for error: any Error
    ) -> BackgroundTaskFailureDisposition {
        if let error = error as? HarcBackgroundURLSessionUploadError {
            switch error {
            case .transportFailed, .capabilityExpired, .bodyUnavailable,
                 .sessionNotInstalled:
                return .failedRecoverable
            case .serverRejected(let statusCode):
                return [408, 425, 429, 500, 502, 503, 504, 507]
                    .contains(statusCode)
                    ? .failedRecoverable
                    : .securityBlocked
            case .invalidEndpointBinding, .corruptEndpointBinding,
                 .bodyIntegrityMismatch, .taskIdentityMismatch,
                 .missingTaskMapping, .missingBackgroundBatch,
                 .invalidPersistedRequest, .responseTooLarge,
                 .invalidHTTPResponse, .acknowledgementValidationFailed,
                 .duplicateBackgroundCompletionHandler,
                 .wrongBackgroundSessionIdentifier:
                return .securityBlocked
            }
        }
        if let error = error as? ClientStoreError {
            return error == .protectedDataUnavailable
                ? .failedRecoverable
                : .securityBlocked
        }
        // At this point request/response/trust validation has already passed;
        // an untyped error is therefore most likely local durable I/O.
        return .failedRecoverable
    }

    private func createMappedTaskAndResume(
        _ job: HarcBackgroundUploadJobV1
    ) throws -> SystemBackgroundTaskIdentity {
        guard job.capability.expiresAt > now() else {
            throw HarcBackgroundURLSessionUploadError.capabilityExpired
        }
        let request = try HarcBackgroundUploadHTTPRequestV1.makeRequest(
            for: job
        )
        let task = try session.makeUploadTask(
            request: request,
            bodyFileURL: job.bodyFileURL
        )
        task.taskDescription = HarcBackgroundUploadHTTPRequestV1
            .taskDescription(batchID: job.descriptor.batchID)
        let identity = try SystemBackgroundTaskIdentity(
            taskIdentifier: task.taskIdentifier
        )
        do {
            try persistence.persistTaskMappingBeforeResume(
                identity,
                batchID: job.descriptor.batchID
            )
        } catch {
            task.cancel()
            throw error
        }
        task.resume()
        return identity
    }

    private func validateHTTPResponse(
        _ event: HarcBackgroundUploadCompletionEventV1,
        job: HarcBackgroundUploadJobV1
    ) throws {
        guard event.response.url?.absoluteString
                == job.endpointBinding.absoluteUploadURL.absoluteString else {
            throw HarcBackgroundURLSessionUploadError
                .invalidHTTPResponse(field: "url")
        }
        guard event.response.statusCode == 200 else {
            throw HarcBackgroundURLSessionUploadError.serverRejected(
                statusCode: event.response.statusCode ?? 0
            )
        }
        guard event.response.contentType
                == HarcBackgroundUploadHTTPRequestV1
                    .acknowledgementContentType else {
            throw HarcBackgroundURLSessionUploadError
                .invalidHTTPResponse(field: "contentType")
        }
        guard event.response.contentEncoding == nil else {
            throw HarcBackgroundURLSessionUploadError
                .invalidHTTPResponse(field: "contentEncoding")
        }
        guard event.response.cacheControl?.lowercased() == "no-store" else {
            throw HarcBackgroundURLSessionUploadError
                .invalidHTTPResponse(field: "cacheControl")
        }
        guard !event.responseBody.isEmpty,
              event.responseBody.count
                <= HarcBackgroundUploadHTTPRequestV1
                    .maximumAcknowledgementBytes,
              event.response.contentLength
                == String(event.responseBody.count) else {
            throw HarcBackgroundURLSessionUploadError
                .invalidHTTPResponse(field: "contentLength")
        }
    }

    private static func verifyHARCAB1Body(
        _ job: HarcBackgroundUploadJobV1
    ) throws {
        let scan = try HarcAudioBatchFileV1.scan(
            at: job.bodyFileURL,
            expectedGeneration: job.descriptor.generation,
            expectedExactBodyByteLength:
                job.descriptor.exactBodyByteLength,
            expectedExactBodySHA256:
                job.descriptor.exactBodySHA256,
            consume: { _ in }
        )
        guard scan.descriptor == job.descriptor else {
            throw HarcBackgroundURLSessionUploadError
                .bodyIntegrityMismatch
        }
    }
}

final class HarcBackgroundEventCompletionGateV1: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingWork = 0
    private var systemFinishedEvents = false
    private var completionHandler: (@Sendable () -> Void)?

    func install(
        _ completionHandler: @escaping @Sendable () -> Void
    ) throws {
        let deliver: (@Sendable () -> Void)?
        lock.lock()
        if self.completionHandler != nil {
            lock.unlock()
            throw HarcBackgroundURLSessionUploadError
                .duplicateBackgroundCompletionHandler
        }
        self.completionHandler = completionHandler
        deliver = takeDeliverableLocked()
        lock.unlock()
        deliverOnMain(deliver)
    }

    func workBegan() {
        lock.lock()
        pendingWork += 1
        lock.unlock()
    }

    func workEnded() {
        let deliver: (@Sendable () -> Void)?
        lock.lock()
        precondition(pendingWork > 0)
        pendingWork -= 1
        deliver = takeDeliverableLocked()
        lock.unlock()
        deliverOnMain(deliver)
    }

    func systemFinished() {
        let deliver: (@Sendable () -> Void)?
        lock.lock()
        systemFinishedEvents = true
        deliver = takeDeliverableLocked()
        lock.unlock()
        deliverOnMain(deliver)
    }

    private func takeDeliverableLocked() -> (@Sendable () -> Void)? {
        guard systemFinishedEvents,
              pendingWork == 0,
              let completionHandler else { return nil }
        self.completionHandler = nil
        systemFinishedEvents = false
        return completionHandler
    }

    private func deliverOnMain(
        _ completionHandler: (@Sendable () -> Void)?
    ) {
        guard let completionHandler else { return }
        DispatchQueue.main.async(execute: completionHandler)
    }
}

public struct HarcBackgroundUploadDelegateFailureV1: Equatable, Sendable {
    public let taskIdentifier: Int
    public let errorDescription: String

    public init(taskIdentifier: Int, errorDescription: String) {
        self.taskIdentifier = taskIdentifier
        self.errorDescription = errorDescription
    }
}

final class HarcBackgroundURLSessionDelegateV1: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    typealias Completion = @Sendable (
        HarcBackgroundUploadCompletionEventV1
    ) async -> Void

    private struct ResponseAccumulator {
        var bytes = Data()
        var overflowed = false
    }

    private let pinnedTrustDelegate: HarcPinnedURLSessionTrustDelegate
    private let didComplete: Completion
    private let completionGate: HarcBackgroundEventCompletionGateV1
    private let lock = NSLock()
    private var responseBodies: [Int: ResponseAccumulator] = [:]

    init(
        pinnedTrustDelegate: HarcPinnedURLSessionTrustDelegate,
        completionGate: HarcBackgroundEventCompletionGateV1,
        didComplete: @escaping Completion
    ) {
        self.pinnedTrustDelegate = pinnedTrustDelegate
        self.completionGate = completionGate
        self.didComplete = didComplete
        super.init()
    }

    func installBackgroundCompletionHandler(
        sessionIdentifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) throws {
        guard sessionIdentifier
                == SystemBackgroundTaskIdentity.stableSessionIdentifier else {
            throw HarcBackgroundURLSessionUploadError
                .wrongBackgroundSessionIdentifier
        }
        try completionGate.install(completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        pinnedTrustDelegate.urlSession(
            session,
            didReceive: challenge,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        pinnedTrustDelegate.urlSession(
            session,
            didReceive: challenge,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive _: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        lock.lock()
        responseBodies[dataTask.taskIdentifier] = ResponseAccumulator()
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel: Bool
        lock.lock()
        var accumulator = responseBodies[dataTask.taskIdentifier]
            ?? ResponseAccumulator()
        if accumulator.overflowed
            || data.count
                > HarcBackgroundUploadHTTPRequestV1
                    .maximumAcknowledgementBytes
                    - accumulator.bytes.count {
            accumulator.overflowed = true
            accumulator.bytes.removeAll(keepingCapacity: false)
            shouldCancel = true
        } else {
            accumulator.bytes.append(data)
            shouldCancel = false
        }
        responseBodies[dataTask.taskIdentifier] = accumulator
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        let accumulator = responseBodies.removeValue(
            forKey: task.taskIdentifier
        ) ?? ResponseAccumulator()
        lock.unlock()

        let failure: HarcBackgroundURLSessionUploadError?
        if accumulator.overflowed {
            failure = .responseTooLarge
        } else if let error {
            let error = error as NSError
            failure = .transportFailed(
                domain: error.domain,
                code: error.code
            )
        } else {
            failure = nil
        }
        let event = HarcBackgroundUploadCompletionEventV1(
            taskIdentifier: task.taskIdentifier,
            taskDescription: task.taskDescription,
            originalRequest: task.originalRequest,
            response: HarcBackgroundUploadHTTPResponseV1(task.response),
            responseBody: accumulator.bytes,
            responseOverflowed: accumulator.overflowed,
            transportFailure: failure
        )

        completionGate.workBegan()
        Task { [didComplete, completionGate] in
            await didComplete(event)
            completionGate.workEnded()
        }
    }

    func urlSessionDidFinishEvents(
        forBackgroundURLSession _: URLSession
    ) {
        completionGate.systemFinished()
    }
}

public enum HarcBackgroundURLSessionConfigurationV1 {
    public static let stableIdentifier =
        SystemBackgroundTaskIdentity.stableSessionIdentifier

    /// iOS receives the one stable launch-events session. macOS uses a normal
    /// session so the shared package and deterministic tests do not claim iOS
    /// relaunch semantics that Foundation does not provide there.
    public static func makeProduction() -> URLSessionConfiguration {
        let configuration: URLSessionConfiguration
        #if os(iOS)
        configuration = .background(withIdentifier: stableIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        #else
        configuration = .default
        #endif

        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.waitsForConnectivity = true
        return configuration
    }
}

/// Production facade for HARCAB1 background PUTs. The object must be retained
/// for the process lifetime so its URLSession delegate can receive relaunch
/// callbacks and drain the application completion handler after durable ACK
/// processing finishes.
public final class HarcBackgroundURLSessionUploadClientV1:
    HarcBackgroundUploadSchedulingV1, @unchecked Sendable
{
    public typealias CompletionReporter = @Sendable (AudioBatchID) async -> Void
    public typealias FailureReporter = @Sendable (
        HarcBackgroundUploadDelegateFailureV1
    ) async -> Void

    private let coordinator: HarcBackgroundUploadCoordinatorV1
    private let delegate: HarcBackgroundURLSessionDelegateV1
    private let foundationSession: URLSession

    private init(
        coordinator: HarcBackgroundUploadCoordinatorV1,
        delegate: HarcBackgroundURLSessionDelegateV1,
        foundationSession: URLSession
    ) {
        self.coordinator = coordinator
        self.delegate = delegate
        self.foundationSession = foundationSession
    }

    public static func makeProduction(
        store: HarcTransferStore,
        completionReporter: @escaping CompletionReporter = { _ in },
        failureReporter: @escaping FailureReporter = { _ in }
    ) -> HarcBackgroundURLSessionUploadClientV1 {
        make(
            store: store,
            configuration:
                HarcBackgroundURLSessionConfigurationV1.makeProduction(),
            now: Date.init,
            completionReporter: completionReporter,
            failureReporter: failureReporter
        )
    }

    package static func make(
        store: HarcTransferStore,
        configuration: URLSessionConfiguration,
        now: @escaping @Sendable () -> Date,
        completionReporter: @escaping CompletionReporter = { _ in },
        failureReporter: @escaping FailureReporter = { _ in }
    ) -> HarcBackgroundURLSessionUploadClientV1 {
        let persistence = HarcTransferStoreBackgroundUploadPersistenceV1(
            store: store
        )
        let sessionBox = HarcBackgroundUploadSessionBoxV1()
        let coordinator = HarcBackgroundUploadCoordinatorV1(
            persistence: persistence,
            session: sessionBox,
            now: now
        )
        let trustCoordinator = HarcTransportTrustCoordinator(
            adoptedPersistence:
                HarcTransferStoreTransportTrustPersistenceV1(store: store)
        )
        let pinnedTrust = HarcPinnedURLSessionTrustDelegate(
            trustCoordinator: trustCoordinator
        )
        let completionGate = HarcBackgroundEventCompletionGateV1()
        let delegate = HarcBackgroundURLSessionDelegateV1(
            pinnedTrustDelegate: pinnedTrust,
            completionGate: completionGate
        ) { [coordinator, completionReporter, failureReporter] event in
            do {
                let batchID = try await coordinator.handleCompletion(event)
                await completionReporter(batchID)
            } catch {
                await failureReporter(
                    HarcBackgroundUploadDelegateFailureV1(
                        taskIdentifier: event.taskIdentifier,
                        errorDescription: String(reflecting: error)
                    )
                )
            }
        }
        let delegateQueue = OperationQueue()
        delegateQueue.name = "xyz.harc.background-upload.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        let foundationSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        sessionBox.install(
            HarcFoundationBackgroundUploadSessionV1(
                session: foundationSession
            )
        )
        return HarcBackgroundURLSessionUploadClientV1(
            coordinator: coordinator,
            delegate: delegate,
            foundationSession: foundationSession
        )
    }

    public func schedule(
        _ plan: HarcBackgroundUploadSchedulingPlanV1
    ) async throws -> SystemBackgroundTaskIdentity {
        try await coordinator.schedule(plan)
    }

    public func reconcileAfterRelaunch() async throws
        -> HarcBackgroundUploadRelaunchResultV1 {
        try await coordinator.reconcileAfterRelaunch()
    }

#if DEBUG
    /// Credential-free task telemetry for physical-device qualification.
    /// URLs and request headers are deliberately excluded.
    public func debugTaskSummary() async -> [String] {
        await withCheckedContinuation { continuation in
            foundationSession.getAllTasks { tasks in
                continuation.resume(returning: tasks.map { task in
                    let state = switch task.state {
                    case .running: "running"
                    case .suspended: "suspended"
                    case .canceling: "canceling"
                    case .completed: "completed"
                    @unknown default: "unknown"
                    }
                    let errorCode = task.error.map {
                        let error = $0 as NSError
                        return "\(error.domain):\(error.code)"
                    } ?? "none"
                    return "task=\(task.taskIdentifier) state=\(state) "
                        + "sent=\(task.countOfBytesSent)/"
                        + "\(task.countOfBytesExpectedToSend) "
                        + "received=\(task.countOfBytesReceived) "
                        + "error=\(errorCode)"
                })
            }
        }
    }
#endif

    /// Call from the iOS application delegate's
    /// `handleEventsForBackgroundURLSession`. The handler is invoked exactly
    /// once, on the main queue, only after Foundation finished delivering
    /// events and every ACK validation/persistence callback has returned.
    public func installBackgroundEventsCompletionHandler(
        sessionIdentifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) throws {
        try delegate.installBackgroundCompletionHandler(
            sessionIdentifier: sessionIdentifier,
            completionHandler: completionHandler
        )
    }

    /// Explicit destructive user action only. Ordinary app shutdown, window
    /// close, or force-quit must leave the stable system session intact.
    public func abandonAllPendingSystemUploadsAfterUserConfirmation() {
        foundationSession.invalidateAndCancel()
    }
}
#endif
