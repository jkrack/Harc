import Foundation
import HarcDomain
@testable import HarcIdentity
import HarcTransfer
@testable import HarcClientStore

enum ClientStoreFixtures {
    static let baseDate = Date(timeIntervalSince1970: 2_050_000_000)

    static func bytes(_ byte: UInt8, count: Int = 32) -> Data {
        Data(repeating: byte, count: count)
    }

    static func signingKey(_ byte: UInt8 = 1) -> SoftwareP256SigningKey {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = byte == 0 ? 1 : byte
        return try! SoftwareP256SigningKey(rawRepresentation: scalar)
    }

    static func uuid(_ value: UInt32) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012u", value))!
    }

    static func device(_ byte: UInt8 = 1) -> DeviceID {
        signingKey(byte).publicKey.deviceID
    }

    static func authority(_ byte: UInt8) -> HostAuthorityID {
        signingKey(byte).publicKey.hostAuthorityID
    }

    static func origin(deviceByte: UInt8 = 1, recording: UInt32 = 1) -> OriginRecordingID {
        OriginRecordingID(
            deviceID: device(deviceByte),
            recordingUUID: uuid(recording)
        )
    }

    static func tuple(library: UInt32, authorityByte: UInt8) -> AdoptedTrustTuple {
        AdoptedTrustTuple(
            libraryID: LibraryID(uuid(library)),
            hostAuthorityID: authority(authorityByte)
        )
    }

    static func authorityKey(_ byte: UInt8) -> Data {
        signingKey(byte).publicKey.rawBytes
    }

    static func hostTrust(
        tuple: AdoptedTrustTuple,
        keyByte: UInt8
    ) -> RecordingHostTrustBinding {
        try! RecordingHostTrustBinding(
            libraryID: tuple.libraryID,
            hostAuthorityID: tuple.hostAuthorityID,
            hostAuthorityPublicKey: signingKey(keyByte).publicKey
        )
    }

    static func transportEvidence(
        tuple: AdoptedTrustTuple,
        keyByte: UInt8,
        epoch: UInt64,
        exactSignedBytes: Data
    ) -> ValidatedTransportSetEvidence {
        try! ValidatedTransportSetEvidence(
            hostTrust: hostTrust(tuple: tuple, keyByte: keyByte),
            epoch: epoch,
            exactSignedBytes: exactSignedBytes
        )
    }

    static func grantEvidence(
        tuple: AdoptedTrustTuple,
        keyByte: UInt8,
        grantID: GrantID,
        deviceByte: UInt8 = 1,
        protocolVersion: IdentityProtocolVersion = .v1,
        scopes: [AuthorizationScope] = [.recordingUploadOwn],
        registryEpoch: UInt64,
        issuedAt: Date = baseDate,
        expiresAt: Date? = nil,
        minimumCompatibleProtocolMinor: UInt16 = 0,
        maximumCompatibleProtocolMinor: UInt16 = 0,
        status: ValidatedDeviceGrantStatus,
        exactSignedBytes: Data
    ) -> ValidatedDeviceGrantEvidence {
        let devicePublicKey = signingKey(deviceByte).publicKey
        let claims = try! DeviceGrantClaims(
            protocolVersion: protocolVersion,
            libraryID: tuple.libraryID,
            hostAuthorityID: tuple.hostAuthorityID,
            grantID: grantID,
            devicePublicKey: devicePublicKey,
            scopes: Set(scopes),
            grantEpoch: GrantEpoch(registryEpoch),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
            maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor
        )
        return try! ValidatedDeviceGrantEvidence(
            hostTrust: hostTrust(tuple: tuple, keyByte: keyByte),
            claims: claims,
            status: status,
            exactSignedBytes: exactSignedBytes
        )
    }

    static func adoption(
        tuple: AdoptedTrustTuple,
        keyByte: UInt8,
        transportEpoch: UInt64,
        transportByte: UInt8,
        grantEpoch: UInt64,
        grantByte: UInt8,
        deviceByte: UInt8 = 1,
        grantID: GrantID? = nil,
        protocolVersion: IdentityProtocolVersion = .v1,
        scopes: [AuthorizationScope] = [.recordingUploadOwn],
        grantIssuedAt: Date = baseDate,
        grantExpiresAt: Date? = nil,
        minimumCompatibleProtocolMinor: UInt16 = 0,
        maximumCompatibleProtocolMinor: UInt16 = 0,
        status: ValidatedDeviceGrantStatus = .active,
        adoptedAt: Date = baseDate
    ) -> ValidatedClientAdoptionEvidence {
        let hostTrust = hostTrust(tuple: tuple, keyByte: keyByte)
        return try! ValidatedClientAdoptionEvidence(
            hostTrust: hostTrust,
            transportSet: ValidatedTransportSetEvidence(
                hostTrust: hostTrust,
                epoch: transportEpoch,
                exactSignedBytes: Data([transportByte, transportByte &+ 1])
            ),
            grant: grantEvidence(
                tuple: tuple,
                keyByte: keyByte,
                grantID: grantID ?? GrantID(uuid(UInt32(grantEpoch) + 100)),
                deviceByte: deviceByte,
                protocolVersion: protocolVersion,
                scopes: scopes,
                registryEpoch: grantEpoch,
                issuedAt: grantIssuedAt,
                expiresAt: grantExpiresAt,
                minimumCompatibleProtocolMinor: minimumCompatibleProtocolMinor,
                maximumCompatibleProtocolMinor: maximumCompatibleProtocolMinor,
                status: status,
                exactSignedBytes: Data([grantByte, grantByte &+ 1])
            ),
            adoptedAt: adoptedAt
        )
    }

    static func authorityReplacementEvidence(
        replacingTuple: AdoptedTrustTuple,
        replacingKeyByte: UInt8,
        replacement: ValidatedClientAdoptionEvidence
    ) -> ValidatedClientAuthorityReplacementEvidence {
        try! ValidatedClientAuthorityReplacementEvidence(
            replacingHostTrust: hostTrust(
                tuple: replacingTuple,
                keyByte: replacingKeyByte
            ),
            replacementAdoption: replacement
        )
    }

    static func capture(
        origin: OriginRecordingID = origin(),
        frames: UInt64 = 1_000
    ) -> FinalizedCapture {
        try! FinalizedCapture(
            producingDeviceID: origin.deviceID,
            originRecordingID: origin,
            captureStartedAt: baseDate,
            captureEndedAt: baseDate.addingTimeInterval(10),
            captureStartedMonotonicNanoseconds: 1_000,
            captureEndedMonotonicNanoseconds: 10_000_001_000,
            finalizationReason: .userStopped,
            totalCanonicalFrames: frames,
            totalCanonicalBytes: frames * 2,
            canonicalPCMSHA256: try! CanonicalPCMHash(bytes(9)),
            discontinuities: []
        )
    }

    static func profile() -> FrozenUploadProfile {
        try! FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: .cafALAC,
            requiredCapabilities: [try! TransferCapabilityID("transfer.chunk.v1")],
            negotiatedCapabilitiesSHA256: try! NegotiatedCapabilitiesSHA256(bytes(10)),
            profileSHA256: try! UploadProfileSHA256(bytes(11)),
            purpose: .production
        )
    }

    static func chunk(origin: OriginRecordingID = origin()) -> LogicalChunkDescriptor {
        try! LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: ChunkID(uuid(200)),
            chunkIndex: 0,
            canonicalStartFrame: 0,
            canonicalFrameCount: 1_000,
            encoding: .cafALAC,
            encodedByteLength: 1_000,
            encodedSHA256: try! EncodedChunkSHA256(bytes(12)),
            canonicalDecodedByteLength: 2_000,
            canonicalDecodedSHA256: try! CanonicalPCMHash(bytes(13))
        )
    }

    static func attempt(
        origin: OriginRecordingID = origin(),
        uploadID: UploadID = UploadID(uuid(300)),
        beganAt: Date = baseDate
    ) -> UploadAttempt {
        var attempt = try! UploadAttempt(
            uploadID: uploadID,
            ownerDeviceID: origin.deviceID,
            originRecordingID: origin,
            frozenProfile: profile(),
            beganAt: beganAt
        )
        try! attempt.declare([chunk(origin: origin)], generation: .initial, at: beganAt)
        return attempt
    }

    static func batch(
        origin: OriginRecordingID = origin(),
        uploadID: UploadID = UploadID(uuid(300))
    ) -> ImmutableAudioBatchDescriptor {
        try! ImmutableAudioBatchDescriptor(
            batchID: AudioBatchID(uuid(400)),
            uploadID: uploadID,
            generation: .initial,
            uploadProfileSHA256: profile().profileSHA256,
            originRecordingID: origin,
            ownerDeviceID: origin.deviceID,
            chunks: [chunk(origin: origin)],
            exactBodyByteLength: 1_200,
            exactBodySHA256: ImmutableBatchSHA256(bytes(14))
        )
    }

    static func exactObject(
        kind: ExactObjectKind,
        byte: UInt8
    ) -> OpaqueExactObjectSlot {
        try! OpaqueExactObjectSlot(
            kind: kind,
            exactBytes: Data([byte, byte &+ 1]),
            objectSHA256: ExactObjectSHA256(bytes(byte))
        )
    }

    static func summary(
        id: UInt32 = 500,
        revision: UInt64 = 1,
        title: String = "Cached recording"
    ) -> LibraryRecordingSummary {
        try! LibraryRecordingSummary(
            canonicalID: CanonicalRecordingID(uuid(id)),
            originID: origin(recording: id),
            revision: EntityRevision(revision),
            startedAt: baseDate,
            endedAt: baseDate.addingTimeInterval(10),
            title: title
        )
    }
}

/// Coherent package-only validator evidence for persistence-boundary tests.
/// The concrete evidence types stand in for the future PR 4/5 validators;
/// HarcClientStore never manufactures them in production.
struct ClientStoreValidatedEvidenceFixture {
    let tuple: AdoptedTrustTuple
    let adoption: ValidatedClientAdoptionEvidence
    let origin: OriginRecordingID
    let capture: FinalizedCapture
    let chunk: LogicalChunkDescriptor
    let finalizedCapture: ChunkedFinalizedCapture
    let attempt: UploadAttempt
    let manifestEvidence: ValidatedRecordingManifestEvidence
    let receiptEvidence: ValidatedRecordingReceiptEvidence

    init(
        library: UInt32 = 700,
        manifestByte: UInt8 = 24,
        receiptByte: UInt8 = 23
    ) throws {
        let hostPublicKey = SoftwareP256SigningKey().publicKey
        let devicePublicKey = SoftwareP256SigningKey().publicKey
        let tuple = AdoptedTrustTuple(
            libraryID: LibraryID(ClientStoreFixtures.uuid(library)),
            hostAuthorityID: hostPublicKey.hostAuthorityID
        )
        let origin = OriginRecordingID(
            deviceID: devicePublicKey.deviceID,
            recordingUUID: ClientStoreFixtures.uuid(701)
        )
        let capture = ClientStoreFixtures.capture(origin: origin)
        let chunk = ClientStoreFixtures.chunk(origin: origin)
        let finalizedCapture = try ChunkedFinalizedCapture(
            capture: capture,
            chunks: [chunk]
        )
        let attempt = ClientStoreFixtures.attempt(origin: origin)
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: tuple.libraryID,
            hostAuthorityID: tuple.hostAuthorityID,
            hostAuthorityPublicKey: hostPublicKey
        )
        let manifestEvidence = try ValidatedRecordingManifestEvidence(
            hostTrust: hostTrust,
            exactManifestObject: ClientStoreFixtures.exactObject(
                kind: .recordingManifestV1,
                byte: manifestByte
            ),
            uploadID: attempt.uploadID,
            producingDevicePublicKey: devicePublicKey,
            originRecordingID: origin,
            uploadProfileSHA256: attempt.frozenProfile.profileSHA256,
            finalizedCapture: finalizedCapture
        )
        let receiptEvidence = try ValidatedRecordingReceiptEvidence(
            hostTrust: hostTrust,
            exactReceiptObject: ClientStoreFixtures.exactObject(
                kind: .recordingReceiptV1,
                byte: receiptByte
            ),
            validatedManifest: manifestEvidence,
            uploadID: attempt.uploadID,
            originRecordingID: origin,
            signedManifestObjectSHA256: manifestEvidence.exactManifestObject.objectSHA256,
            canonicalPCMSHA256: manifestEvidence.canonicalPCMSHA256,
            totalCanonicalFrames: manifestEvidence.totalCanonicalFrames,
            canonicalFormat: manifestEvidence.canonicalFormat,
            canonicalRecordingID: CanonicalRecordingID(ClientStoreFixtures.uuid(702)),
            canonicalRevision: .initial,
            changeCursor: ChangeCursor(1),
            receiptID: ClientStoreFixtures.uuid(703),
            durableCommitTime: ClientStoreFixtures.baseDate.addingTimeInterval(10),
            processingState: .pending
        )
        let grantClaims = try DeviceGrantClaims(
            libraryID: tuple.libraryID,
            hostAuthorityID: tuple.hostAuthorityID,
            grantID: GrantID(ClientStoreFixtures.uuid(704)),
            devicePublicKey: devicePublicKey,
            scopes: [.recordingUploadOwn],
            grantEpoch: .initial,
            issuedAt: ClientStoreFixtures.baseDate,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        let adoption = try ValidatedClientAdoptionEvidence(
            hostTrust: hostTrust,
            transportSet: ValidatedTransportSetEvidence(
                hostTrust: hostTrust,
                epoch: 1,
                exactSignedBytes: Data([0x71, 0x72])
            ),
            grant: ValidatedDeviceGrantEvidence(
                hostTrust: hostTrust,
                claims: grantClaims,
                status: .active,
                exactSignedBytes: Data([0x73, 0x74])
            ),
            adoptedAt: ClientStoreFixtures.baseDate
        )

        self.tuple = tuple
        self.adoption = adoption
        self.origin = origin
        self.capture = capture
        self.chunk = chunk
        self.finalizedCapture = finalizedCapture
        self.attempt = attempt
        self.manifestEvidence = manifestEvidence
        self.receiptEvidence = receiptEvidence
    }
}

final class RecordingStorageAttributes: ClientStoreStorageAttributeApplying, @unchecked Sendable {
    struct Event: Equatable {
        let policy: ClientStoreStoragePolicy
        let artifact: ClientStoreStorageArtifact
    }

    private let lock = NSLock()
    private var available: Bool
    private var recordedEvents: [Event] = []

    init(available: Bool = true) {
        self.available = available
    }

    func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        lock.unlock()
    }

    func isProtectedDataAvailable(for _: ClientStoreStoragePolicy) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func applyAndVerify(
        _ policy: ClientStoreStoragePolicy,
        to artifact: ClientStoreStorageArtifact
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard available else { throw ClientStoreError.protectedDataUnavailable }
        recordedEvents.append(Event(policy: policy, artifact: artifact))
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

enum InjectedClientStoreFault: Error {
    case stop
}

struct PointFaultInjector: ClientStoreFaultInjecting {
    let point: ClientStoreFaultPoint

    func trigger(_ point: ClientStoreFaultPoint) throws {
        if point == self.point { throw InjectedClientStoreFault.stop }
    }
}

final class StubArtifactInspector: LocalTransferArtifactInspecting, @unchecked Sendable {
    private let existingPaths: Set<String>
    private let mismatchedPaths: Set<String>
    private(set) var inspectedPaths: [String] = []

    init(existingURLs: [URL], mismatchedURLs: [URL] = []) {
        existingPaths = Set(existingURLs.map { $0.standardizedFileURL.path })
        mismatchedPaths = Set(mismatchedURLs.map { $0.standardizedFileURL.path })
    }

    func fileExists(at url: URL) -> Bool {
        inspectedPaths.append(url.standardizedFileURL.path)
        return existingPaths.contains(url.standardizedFileURL.path)
    }

    func exactFileMatches(
        at url: URL,
        expectedByteCount _: UInt64,
        expectedSHA256 _: Data
    ) -> Bool {
        let path = url.standardizedFileURL.path
        return existingPaths.contains(path) && !mismatchedPaths.contains(path)
    }
}

func temporaryClientStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("harc-client-store-\(UUID().uuidString)", isDirectory: true)
}
