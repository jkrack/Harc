import Foundation
import GRDB
import HarcDomain
import HarcIdentity
import HarcTransfer
import Testing
@testable import HarcHost

@Suite("Upload session capability admission")
struct UploadSessionCapabilityAdmissionTests {
    private struct PreparedAdmission {
        let fixture: HostTestFixture
        let directory: URL
        let store: HarcHostStore
        let context: AuthenticatedDeviceContext
        let profile: FrozenUploadProfile
        let request: BeginHostUploadRequest
    }

    private struct DurableUploadSnapshot: Equatable {
        let attemptJSON: Data
        let generation: Int64
        let status: String
        let updatedAt: Double
    }

    @Test("initial capability hash mismatch leaves no upload row")
    func initialHashMismatchIsAtomic() async throws {
        let prepared = try await prepare()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let wrongHash = try NegotiatedCapabilitiesSHA256(
            Data(repeating: 0xFE, count: 32)
        )
        let mismatched = try prepared.fixture.sessionCapabilities(
            for: prepared.profile,
            exactCapabilitiesSHA256: wrongHash
        )

        await #expect(throws: TransferValidationError.profileMismatch(
            field: "negotiatedCapabilitiesSHA256"
        )) {
            _ = try await prepared.store.beginUpload(
                context: prepared.context,
                sessionCapabilities: mismatched,
                request: prepared.request,
                at: prepared.fixture.beganAt.addingTimeInterval(1)
            )
        }

        let rowCount = try await prepared.store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM uploads") ?? -1
        }
        #expect(rowCount == 0)
    }

    @Test("later additive features preserve exact replay and reopen")
    func laterAdditiveFeaturesReplayAndReopen() async throws {
        let prepared = try await prepare()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let initial = try prepared.fixture.sessionCapabilities(for: prepared.profile)
        let acceptedAt = prepared.fixture.beganAt.addingTimeInterval(1)
        guard case .created = try await prepared.store.beginUpload(
            context: prepared.context,
            sessionCapabilities: initial,
            request: prepared.request,
            at: acceptedAt
        ) else {
            Issue.record("Expected initial admission to create an upload")
            return
        }

        let additive = try prepared.fixture.sessionCapabilities(
            for: prepared.profile,
            exactCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(
                Data(repeating: 0xAD, count: 32)
            ),
            selectedFeatureIDs: [
                TransferCapabilityID("capture.gaps.v1"),
                TransferCapabilityID("transfer.chunk.v1"),
            ]
        )
        guard case .exactReplay = try await prepared.store.beginUpload(
            context: prepared.context,
            sessionCapabilities: additive,
            request: prepared.request,
            at: acceptedAt.addingTimeInterval(1)
        ) else {
            Issue.record("Expected a compatible later session to replay")
            return
        }

        let reopenedAt = acceptedAt.addingTimeInterval(
            TransferLimits.uploadGenerationLifetime + 1
        )
        guard case .reopened(let reconciliation) = try await prepared.store.beginUpload(
            context: prepared.context,
            sessionCapabilities: additive,
            request: prepared.request,
            at: reopenedAt
        ) else {
            Issue.record("Expected a compatible later session to reopen")
            return
        }
        #expect(reconciliation.generation.rawValue == 2)
    }

    @Test("transfer semantic drift leaves an admitted upload unchanged")
    func semanticDriftIsAtomic() async throws {
        let prepared = try await prepare()
        defer { try? FileManager.default.removeItem(at: prepared.directory) }
        let initial = try prepared.fixture.sessionCapabilities(for: prepared.profile)
        let acceptedAt = prepared.fixture.beganAt.addingTimeInterval(1)
        _ = try await prepared.store.beginUpload(
            context: prepared.context,
            sessionCapabilities: initial,
            request: prepared.request,
            at: acceptedAt
        )
        let baseline = try await snapshot(
            store: prepared.store,
            uploadID: prepared.request.uploadID
        )

        let minorDrift = try prepared.fixture.sessionCapabilities(
            for: prepared.profile,
            protocolVersion: TransferProtocolVersion(minor: 1)
        )
        let schemaDrift = try HostTransferSessionCapabilities(
            exactCapabilitiesSHA256: prepared.profile.negotiatedCapabilitiesSHA256,
            protocolVersion: prepared.profile.protocolVersion,
            selectedFeatureIDs: prepared.profile.requiredCapabilities,
            descriptorSchemaID: TransferCapabilityID("harc.chunk-descriptor.v2"),
            encoding: prepared.profile.encoding,
            canonicalFormat: prepared.profile.canonicalFormat
        )
        let codecDrift = try prepared.fixture.sessionCapabilities(
            for: prepared.profile,
            encoding: .cafALAC
        )
        let requiredFeatureDrift = try prepared.fixture.sessionCapabilities(
            for: prepared.profile,
            selectedFeatureIDs: []
        )
        let cases: [(String, HostTransferSessionCapabilities)] = [
            ("protocolVersion", minorDrift),
            ("descriptorSchema", schemaDrift),
            ("encoding.codec", codecDrift),
            ("requiredCapabilities", requiredFeatureDrift),
        ]

        for (offset, testCase) in cases.enumerated() {
            await #expect(throws: TransferValidationError.profileMismatch(
                field: testCase.0
            )) {
                _ = try await prepared.store.beginUpload(
                    context: prepared.context,
                    sessionCapabilities: testCase.1,
                    request: prepared.request,
                    at: acceptedAt.addingTimeInterval(Double(offset + 1))
                )
            }
            #expect(try await snapshot(
                store: prepared.store,
                uploadID: prepared.request.uploadID
            ) == baseline)
        }
    }

    private func prepare() async throws -> PreparedAdmission {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        let store = try await HarcHostStore.inMemory(
            stagingRoot: directory,
            metadata: fixture.metadata,
            capacityProvider: FixedHostVolumeCapacityProvider()
        )
        let grant = try fixture.grant()
        try await store.seedDeviceGrantForTesting(
            grant,
            exactGrantBytes: Data("session-capability-grant".utf8)
        )
        let requiredFeature = try TransferCapabilityID("transfer.chunk.v1")
        let profile = try FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: .rawPCMFixture,
            requiredCapabilities: [requiredFeature],
            negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(
                Data(repeating: 0xC1, count: 32)
            ),
            profileSHA256: UploadProfileSHA256(Data(repeating: 0xC2, count: 32)),
            purpose: .fixtureLoopback
        )
        let request = BeginHostUploadRequest(
            uploadID: .random(),
            originRecordingID: OriginRecordingID(
                deviceID: fixture.deviceID,
                recordingUUID: UUID()
            ),
            frozenProfile: profile,
            beganAt: fixture.beganAt.addingTimeInterval(1)
        )
        return PreparedAdmission(
            fixture: fixture,
            directory: directory,
            store: store,
            context: fixture.context(for: grant),
            profile: profile,
            request: request
        )
    }

    private func snapshot(
        store: HarcHostStore,
        uploadID: UploadID
    ) async throws -> DurableUploadSnapshot? {
        try await store.dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT attempt_json, current_generation, attempt_status, updated_at
                    FROM uploads WHERE upload_id = ?
                    """,
                arguments: [uploadID.description]
            ) else { return nil }
            return DurableUploadSnapshot(
                attemptJSON: row["attempt_json"],
                generation: row["current_generation"],
                status: row["attempt_status"],
                updatedAt: row["updated_at"]
            )
        }
    }
}
