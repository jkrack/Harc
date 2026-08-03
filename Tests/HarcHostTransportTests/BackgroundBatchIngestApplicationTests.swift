import CryptoKit
import Foundation
import GRDB
@testable import HarcHost
@testable import HarcHostTransport
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcProtocolWire
import HarcTransfer
import Testing

@Suite("Background HARCAB1 ingest application")
struct BackgroundBatchIngestApplicationTests {
    private final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: Date) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    private struct FixedCapacity: HostVolumeCapacityProvider {
        func capacity(for stagingRoot: URL) throws -> HostVolumeCapacity {
            HostVolumeCapacity(
                availableBytes: 1_000_000_000_000,
                totalBytes: 1_000_000_000_000
            )
        }
    }

    private struct FixedTransportProvider:
        HostBackgroundCapabilityTransportSnapshotProviding
    {
        let exactSignedTransportSet: Data

        func reserveBackgroundCapabilityTransport(
            forHTTPPath httpPath: String,
            capabilityExpiresAt: Date
        ) async throws -> HostBackgroundCapabilityTransportSnapshot {
            try HostBackgroundCapabilityTransportSnapshot(
                absoluteUploadURL: try #require(
                    URL(string: "https://harc-mini.local:7443\(httpPath)")
                ),
                currentTransportSetEpoch: 1,
                exactSignedTransportSet: exactSignedTransportSet
            )
        }
    }

    private struct FixedCapabilityRandomness:
        HostBackgroundCapabilityRandomness
    {
        let capabilityID: UUID

        func generateCapabilityID() throws -> UUID { capabilityID }
        func generateSecret(byteCount: Int) throws -> Data {
            Data(repeating: 0x91, count: byteCount)
        }
    }

    private struct FixedAcknowledgementIDGenerator:
        HarcBackgroundBatchAcknowledgementIDGenerating
    {
        let value = UUID(
            uuidString: "00000000-0000-0000-0000-000000000901"
        )!
        func generateAcknowledgementID() -> UUID { value }
    }

    private enum InjectedFailure: Error, Equatable {
        case point(HarcBackgroundBatchIngestFailurePoint)
    }

    private final class OneShotFailureInjector:
        HarcBackgroundBatchIngestFailureInjecting,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var target: HarcBackgroundBatchIngestFailurePoint?

        init(_ target: HarcBackgroundBatchIngestFailurePoint) {
            self.target = target
        }

        func hit(_ point: HarcBackgroundBatchIngestFailurePoint) throws {
            lock.lock()
            defer { lock.unlock() }
            guard target == point else { return }
            target = nil
            throw InjectedFailure.point(point)
        }
    }

    private struct Fixture {
        let directory: URL
        let rollbackRoot: URL
        let bodyURL: URL
        let store: HarcHostStore
        let hostKey: SoftwareP256SigningKey
        let hostTrust: RecordingHostTrustBinding
        let context: AuthenticatedDeviceContext
        let profile: FrozenUploadProfile
        let descriptors: [LogicalChunkDescriptor]
        let batch: HarcAudioBatchV1
        let mintRequest: HostBackgroundCapabilityMintRequest
        let mintResult: HostBackgroundCapabilityMintResult
        let admission: HostBackgroundBatchAdmission
        let servingGeneration:
            HarcBackgroundUploadServingGenerationBinding
        let clock: LockedClock
        let ingestAt: Date

        func application(
            failureInjector: any HarcBackgroundBatchIngestFailureInjecting =
                NoHarcBackgroundBatchIngestFailureInjector()
        ) throws -> HarcBackgroundBatchIngestApplicationV1 {
            try HarcBackgroundBatchIngestApplicationV1(
                hostStore: store,
                rollbackRoot: rollbackRoot,
                hostTrust: hostTrust,
                hostAuthoritySigner: hostKey,
                acknowledgementIDGenerator:
                    FixedAcknowledgementIDGenerator(),
                failureInjector: failureInjector,
                now: { clock.read() }
            )
        }
    }

    private struct DurableFacts: Sendable {
        let durableChunkCount: Int
        let batchState: String
        let exactACK: Data?
        let capabilityState: String
    }

    private func makeFixture() async throws -> Fixture {
        let hostKey = SoftwareP256SigningKey()
        let deviceKey = SoftwareP256SigningKey()
        let libraryID = LibraryID.random()
        let beganAt = Date(timeIntervalSince1970: 1_800_000_000)
        let ingestAt = beganAt.addingTimeInterval(20)
        let clock = LockedClock(beganAt)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HarcBackgroundBatchIngestTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let stagingRoot = directory.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let rollbackRoot = directory.appendingPathComponent(
            "rollback",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let metadata = HarcHostMetadata(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostStateID: .random()
        )
        let store = try await HarcHostStore.inMemory(
            stagingRoot: stagingRoot,
            metadata: metadata,
            capacityProvider: FixedCapacity(),
            now: { clock.read() }
        )
        let grant = try DeviceGrantClaims(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            grantID: .random(),
            devicePublicKey: deviceKey.publicKey,
            scopes: [.recordingUploadOwn, .recordingReadOwn],
            grantEpoch: .initial,
            issuedAt: beganAt,
            expiresAt: nil,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("background-ingest-grant".utf8)
        )
        let context = AuthenticatedDeviceContext(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            authenticatedDeviceID: deviceKey.publicKey.deviceID,
            grantID: grant.grantID,
            grantEpoch: grant.grantEpoch
        )
        let profile = try FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: .rawPCMFixture,
            requiredCapabilities: [],
            negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(
                Data(repeating: 0x31, count: 32)
            ),
            profileSHA256: UploadProfileSHA256(
                Data(repeating: 0x32, count: 32)
            ),
            purpose: .fixtureLoopback
        )
        let uploadID = UploadID.random()
        let origin = OriginRecordingID(
            deviceID: deviceKey.publicKey.deviceID,
            recordingUUID: UUID()
        )
        let chunks = [
            Data([0, 1, 2, 3, 4, 5, 6, 7]),
            Data([8, 9, 10, 11, 12, 13, 14, 15]),
        ]
        var startFrame: UInt64 = 0
        let descriptors = try chunks.enumerated().map { index, bytes in
            let digest = Data(SHA256.hash(data: bytes))
            let descriptor = try LogicalChunkDescriptor(
                originRecordingID: origin,
                chunkID: .random(),
                chunkIndex: UInt32(index),
                canonicalStartFrame: startFrame,
                canonicalFrameCount: UInt64(bytes.count / 2),
                encoding: .rawPCMFixture,
                encodedByteLength: UInt64(bytes.count),
                encodedSHA256: EncodedChunkSHA256(digest),
                canonicalDecodedByteLength: UInt64(bytes.count),
                canonicalDecodedSHA256: CanonicalPCMHash(digest)
            )
            startFrame += UInt64(bytes.count / 2)
            return descriptor
        }
        let batchID = AudioBatchID.random()
        let batch = try makeBatch(
            batchID: batchID,
            uploadID: uploadID,
            profile: profile,
            origin: origin,
            ownerDeviceID: deviceKey.publicKey.deviceID,
            descriptors: descriptors,
            chunks: chunks
        )
        let bodyURL = directory.appendingPathComponent(
            "received-body.harcab1",
            isDirectory: false
        )
        try batch.exactBytes.write(to: bodyURL, options: .atomic)

        let began = try await store.beginUpload(
            context: context,
            sessionCapabilities: HostTransferSessionCapabilities(
                exactCapabilitiesSHA256:
                    profile.negotiatedCapabilitiesSHA256,
                protocolVersion: profile.protocolVersion,
                selectedFeatureIDs: profile.requiredCapabilities,
                descriptorSchema: profile.descriptorSchema,
                encoding: profile.encoding,
                canonicalFormat: profile.canonicalFormat
            ),
            request: BeginHostUploadRequest(
                uploadID: uploadID,
                originRecordingID: origin,
                frozenProfile: profile,
                beganAt: beganAt.addingTimeInterval(1)
            ),
            at: beganAt.addingTimeInterval(1)
        )
        guard case .created = began else {
            throw HarcHostError.uploadConflict("test setup")
        }
        _ = try await store.declareChunks(
            context: context,
            uploadID: uploadID,
            generation: .initial,
            expectedUploadProfileSHA256: profile.profileSHA256,
            descriptors: descriptors,
            at: beganAt.addingTimeInterval(2)
        )

        let exactTransportSet = Data("background-ingest-transport".utf8)
        let transportObjectID = Data(SHA256.hash(data: exactTransportSet))
        try await store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO host_transport_sets (
                        epoch, exact_signed_bytes, object_id, publication_kind,
                        issued_at_unix_ms, published_at,
                        retirement_floor_unix_ms
                    ) VALUES (1, ?, ?, 'initial', 1, ?, 0)
                    """,
                arguments: [
                    exactTransportSet,
                    transportObjectID,
                    HarcHostStore.unixTime(beganAt.addingTimeInterval(3)),
                ]
            )
            try db.execute(
                sql: """
                    UPDATE host_metadata
                       SET highest_transport_set_epoch = 1,
                           exact_transport_set_bytes = ?,
                           transport_set_object_sha256 = ?,
                           updated_at = ?
                     WHERE singleton = 1
                    """,
                arguments: [
                    exactTransportSet,
                    transportObjectID,
                    HarcHostStore.unixTime(beganAt.addingTimeInterval(3)),
                ]
            )
        }
        let mintRequest = try HostBackgroundCapabilityMintRequest(
            uploadID: uploadID,
            generation: .initial,
            uploadProfileSHA256: profile.profileSHA256,
            batchID: batchID,
            chunks: descriptors.map {
                HostBackgroundChunkBinding(
                    chunkIndex: $0.chunkIndex,
                    encodedSHA256: $0.encodedSHA256
                )
            },
            exactBatchBodySHA256: ImmutableBatchSHA256(batch.exactSHA256),
            exactBatchBodyLength: UInt64(batch.exactBytes.count),
            requestedExpiresAt: beganAt.addingTimeInterval(7 * 24 * 60 * 60)
        )
        let provider = FixedTransportProvider(
            exactSignedTransportSet: exactTransportSet
        )
        let mintResult = try await store.mintBackgroundCapability(
            context: context,
            request: mintRequest,
            transportSnapshotProvider: provider,
            randomness: FixedCapabilityRandomness(
                capabilityID: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000902"
                )!
            ),
            at: beganAt.addingTimeInterval(4)
        )
        let servingGeneration = try
            HarcBackgroundUploadServingGenerationBinding(
                generationID: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000903"
                )!,
                transportSetEpoch: 1
            )
        let hostTrust = try RecordingHostTrustBinding(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostAuthorityPublicKey: hostKey.publicKey
        )
        clock.set(beganAt.addingTimeInterval(5))
        let application = try HarcBackgroundBatchIngestApplicationV1(
            hostStore: store,
            rollbackRoot: rollbackRoot,
            hostTrust: hostTrust,
            hostAuthoritySigner: hostKey,
            acknowledgementIDGenerator:
                FixedAcknowledgementIDGenerator(),
            now: { clock.read() }
        )
        let admission = try await application.admit(
            HostBackgroundCapabilityAdmissionRequest(
                opaqueCapabilityCredential:
                    mintResult.opaqueCapabilityCredential,
                httpMethod: mintResult.httpMethod,
                httpPath: mintResult.httpPath,
                contentLength: mintResult.byteCeiling
            ),
            servedBy: servingGeneration
        )
        clock.set(ingestAt)
        return Fixture(
            directory: directory,
            rollbackRoot: rollbackRoot,
            bodyURL: bodyURL,
            store: store,
            hostKey: hostKey,
            hostTrust: hostTrust,
            context: context,
            profile: profile,
            descriptors: descriptors,
            batch: batch,
            mintRequest: mintRequest,
            mintResult: mintResult,
            admission: admission,
            servingGeneration: servingGeneration,
            clock: clock,
            ingestAt: ingestAt
        )
    }

    private func makeBatch(
        batchID: AudioBatchID,
        uploadID: UploadID,
        profile: FrozenUploadProfile,
        origin: OriginRecordingID,
        ownerDeviceID: DeviceID,
        descriptors: [LogicalChunkDescriptor],
        chunks: [Data]
    ) throws -> HarcAudioBatchV1 {
        var header = Harc_V1_AudioBatchHeaderV1()
        header.protocol.major = 1
        header.protocol.minor = 0
        header.batchID.value = uuidBytes(batchID.rawValue)
        header.uploadID.value = uuidBytes(uploadID.rawValue)
        header.uploadProfileSha256.value = profile.profileSHA256.rawBytes
        header.originRecordingID.deviceID.sha256 = origin.deviceID.rawBytes
        header.originRecordingID.recordingUuid = uuidBytes(
            origin.recordingUUID
        )
        header.deviceID.sha256 = ownerDeviceID.rawBytes
        header.entries = descriptors.map { descriptor in
            var entry = Harc_V1_AudioBatchEntryV1()
            entry.chunkID.value = uuidBytes(descriptor.chunkID.rawValue)
            entry.chunkIndex = descriptor.chunkIndex
            entry.encodedLength = UInt32(descriptor.encodedByteLength)
            entry.encodedSha256.value = descriptor.encodedSHA256.rawBytes
            entry.canonicalStartFrame = descriptor.canonicalStartFrame
            entry.canonicalFrameCount = descriptor.canonicalFrameCount
            entry.canonicalDecodedSha256.value =
                descriptor.canonicalDecodedSHA256.rawBytes
            entry.encoding.codec =
                .losslessAudioCodecRawCanonicalPcmFixture
            entry.encoding.container =
                .losslessAudioContainerRawCanonicalPcmFixture
            return entry
        }
        return try HarcAudioBatchV1.create(
            header: header,
            encodedChunks: chunks
        )
    }

    private func durableFacts(_ fixture: Fixture) async throws -> DurableFacts {
        try await fixture.store.dbQueue.read { db in
            let row = try #require(try Row.fetchOne(
                db,
                sql: """
                    SELECT batch.state AS batch_state, batch.exact_ack_bytes,
                           capability.state AS capability_state
                      FROM upload_batches AS batch
                      JOIN background_capabilities AS capability
                        ON capability.batch_id = batch.batch_id
                     WHERE capability.capability_id = ?
                    """,
                arguments: [
                    fixture.mintResult.capabilityID.uuidString.lowercased()
                ]
            ))
            return DurableFacts(
                durableChunkCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM staged_chunks WHERE status = 'durable'"
                ) ?? -1,
                batchState: row["batch_state"],
                exactACK: row["exact_ack_bytes"],
                capabilityState: row["capability_state"]
            )
        }
    }

    private func rollbackChildren(_ fixture: Fixture) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: fixture.rollbackRoot.path)
        else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: fixture.rollbackRoot,
            includingPropertiesForKeys: nil
        )
    }

    @Test("verified HARCAB1 stages exact chunks and returns one canonical signed ACK")
    func successfulIngestAndReplay() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let application = try fixture.application()
        let result = try await application.ingest(
            secureTemporaryBodyURL: fixture.bodyURL,
            admission: fixture.admission
        )
        let evidence = try HarcBatchAcknowledgementCodecV1()
            .validateBatchAcknowledgement(
                exactSignedAcknowledgementBytes:
                    result.exactAcknowledgementBytes,
                batch: result.batch,
                hostTrust: fixture.hostTrust
            )
        #expect(evidence.batchID == fixture.mintRequest.batchID)
        #expect(evidence.durableChunks.map(\.chunkIndex) == [0, 1])
        let facts = try await durableFacts(fixture)
        #expect(facts.durableChunkCount == 2)
        #expect(facts.batchState == "accepted")
        #expect(facts.capabilityState == "accepted")
        #expect(facts.exactACK == result.exactAcknowledgementBytes)
        #expect(try rollbackChildren(fixture).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.bodyURL.path))

        let replayAdmission = try await application.admit(
            HostBackgroundCapabilityAdmissionRequest(
                opaqueCapabilityCredential:
                    fixture.mintResult.opaqueCapabilityCredential,
                httpMethod: fixture.mintResult.httpMethod,
                httpPath: fixture.mintResult.httpPath,
                contentLength: fixture.mintResult.byteCeiling
            ),
            servedBy: fixture.servingGeneration
        )
        var tamperedReplayBody = fixture.batch.exactBytes
        tamperedReplayBody[
            tamperedReplayBody.index(before: tamperedReplayBody.endIndex)
        ] ^= 0x01
        try tamperedReplayBody.write(
            to: fixture.bodyURL,
            options: .atomic
        )
        await #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            _ = try await application.ingest(
                secureTemporaryBodyURL: fixture.bodyURL,
                admission: replayAdmission
            )
        }
        try fixture.batch.exactBytes.write(
            to: fixture.bodyURL,
            options: .atomic
        )
        let replay = try await application.ingest(
            secureTemporaryBodyURL: fixture.bodyURL,
            admission: replayAdmission
        )
        #expect(replay.exactAcknowledgementBytes
            == result.exactAcknowledgementBytes)
        #expect(try await durableFacts(fixture).durableChunkCount == 2)
        #expect(try rollbackChildren(fixture).isEmpty)
    }

    @Test("production-style sub-millisecond host time is canonicalized for the signed ACK")
    func submillisecondClockIsCanonicalized() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let rawHostTime = fixture.ingestAt.addingTimeInterval(0.000_789)
        fixture.clock.set(rawHostTime)

        let result = try await fixture.application().ingest(
            secureTemporaryBodyURL: fixture.bodyURL,
            admission: fixture.admission
        )
        let evidence = try HarcBatchAcknowledgementCodecV1()
            .validateBatchAcknowledgement(
                exactSignedAcknowledgementBytes:
                    result.exactAcknowledgementBytes,
                batch: result.batch,
                hostTrust: fixture.hostTrust
            )
        let expected = Date(
            timeIntervalSince1970:
                (rawHostTime.timeIntervalSince1970 * 1_000)
                .rounded(.down) / 1_000
        )
        #expect(evidence.durableAt == expected)
    }

    @Test("tampered body rolls back scan output before any durable staging")
    func tamperRollback() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var tampered = fixture.batch.exactBytes
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: fixture.bodyURL, options: .atomic)
        let application = try fixture.application()
        await #expect(throws: HarcProtocolCodecError.payloadHashMismatch) {
            _ = try await application.ingest(
                secureTemporaryBodyURL: fixture.bodyURL,
                admission: fixture.admission
            )
        }
        let facts = try await durableFacts(fixture)
        #expect(facts.durableChunkCount == 0)
        #expect(facts.batchState == "awaiting-upload")
        #expect(facts.exactACK == nil)
        #expect(try rollbackChildren(fixture).isEmpty)
    }

    @Test("crash boundaries leave no false ACK and an exact retry converges")
    func crashBoundariesAndRetry() async throws {
        let cases: [(
            point: HarcBackgroundBatchIngestFailurePoint,
            durableChunks: Int,
            ackPersisted: Bool
        )] = [
            (.afterRollbackChunkWrite, 0, false),
            (.afterWholeBodyVerification, 0, false),
            (.afterChunkStaged, 1, false),
            (.afterAcknowledgementIssued, 2, false),
            (.afterAcknowledgementPersisted, 2, true),
        ]
        for testCase in cases {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let crashing = try fixture.application(
                failureInjector: OneShotFailureInjector(testCase.point)
            )
            await #expect(throws: InjectedFailure.point(testCase.point)) {
                _ = try await crashing.ingest(
                    secureTemporaryBodyURL: fixture.bodyURL,
                    admission: fixture.admission
                )
            }
            let interrupted = try await durableFacts(fixture)
            #expect(interrupted.durableChunkCount == testCase.durableChunks)
            #expect((interrupted.exactACK != nil) == testCase.ackPersisted)
            #expect(try rollbackChildren(fixture).isEmpty)

            let retry = try fixture.application()
            let retryAdmission = try await retry.admit(
                    HostBackgroundCapabilityAdmissionRequest(
                        opaqueCapabilityCredential:
                            fixture.mintResult.opaqueCapabilityCredential,
                        httpMethod: fixture.mintResult.httpMethod,
                        httpPath: fixture.mintResult.httpPath,
                        contentLength: fixture.mintResult.byteCeiling
                    ),
                    servedBy: fixture.servingGeneration
                )
            let result = try await retry.ingest(
                secureTemporaryBodyURL: fixture.bodyURL,
                admission: retryAdmission
            )
            let completed = try await durableFacts(fixture)
            #expect(completed.durableChunkCount == 2)
            #expect(completed.batchState == "accepted")
            #expect(completed.capabilityState == "accepted")
            #expect(completed.exactACK == result.exactAcknowledgementBytes)
            #expect(try rollbackChildren(fixture).isEmpty)
        }
    }

    private func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }
}
