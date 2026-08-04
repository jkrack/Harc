import Darwin
import Foundation
import GRDB
import HarcDomain
import Testing
@testable import HarcStore

@Suite("Host writer lease and canonical commit")
struct HostWriterLeaseTests {
    private let startedAt = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Host mode owns one lifetime lock and disables under the same lease")
    func enableContentionDisable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        let metadata = try await fixture.store.libraryMetadata()
        #expect(metadata.writerMode == .host)
        #expect(metadata.libraryID == fixture.libraryID)
        #expect(metadata.hostAuthorityID == fixture.authorityID)
        #expect(metadata.hostStateID == fixture.stateID)
        #expect(lease.identity.libraryID == fixture.libraryID)
        #expect(lease.lockFileURL.path == fixture.databaseURL.path + ".writer.lock")

        let lockAttributes = try FileManager.default.attributesOfItem(
            atPath: lease.lockFileURL.path
        )
        #expect((lockAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
        #expect((lockAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let contender = try await RecordingStore.onDisk(url: fixture.databaseURL)
        do {
            _ = try await contender.resumeHostMode(
                expectedLibraryID: fixture.libraryID,
                hostAuthorityID: fixture.authorityID,
                hostStateID: fixture.stateID,
                waitForLock: false
            )
            Issue.record("A second process/store must not acquire the live Host lease")
        } catch let error as StoreError {
            #expect(error == .writerLeaseUnavailable)
        }

        try await fixture.store.disableHostMode(lease)
        let disabled = try await fixture.store.libraryMetadata()
        #expect(disabled.writerMode == .standalone)
        #expect(disabled.hostAuthorityID == fixture.authorityID)
        #expect(disabled.hostStateID == fixture.stateID)

        let row = try await contender.upsert(
            Recording(wavPath: fixture.root.appendingPathComponent("local.wav").path,
                      startedAt: startedAt)
        )
        #expect(row.id != nil)
    }

    @Test("External authority calls use nonblocking shared/exclusive locks")
    func externalAuthorityLocksFailClosedDuringHostLifetime() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        // Open before adoption to model a long-lived MCP process. The store
        // itself retains no advisory lock between individual calls.
        let external = try await RecordingStore
            .onDiskForExternalAuthorityRouting(url: fixture.databaseURL)
        _ = try await external.fetchAll()

        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )

        do {
            _ = try await external.fetchAll()
            Issue.record("A direct read must not cross the Host lifetime lease")
        } catch let error as StoreError {
            #expect(error == .writerLeaseUnavailable)
        }

        do {
            _ = try await external.upsert(
                Recording(
                    wavPath: fixture.root.appendingPathComponent("blocked.wav").path,
                    startedAt: startedAt
                )
            )
            Issue.record("A direct mutation must not cross the Host lifetime lease")
        } catch let error as StoreError {
            #expect(error == .writerLeaseUnavailable)
        }

        try await fixture.store.disableHostMode(lease)
        _ = try await external.fetchAll()
    }

    @Test("Process death releases flock but leaves a fail-closed Host marker")
    func processDeathMarkerAndExactResume() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        try await fixture.store.abandonHostLeaseForTesting(lease)

        let afterDeath = try RecordingStore.inspectLibraryMetadata(
            onDiskAt: fixture.databaseURL
        )
        #expect(afterDeath.writerMode == .host)

        let lockHolder = Process()
        let readyPipe = Pipe()
        lockHolder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        lockHolder.arguments = [
            "-MFcntl=:flock",
            "-e",
            "$|=1; open(my $fh, '>>', $ARGV[0]) or die; "
                + "flock($fh, LOCK_EX) or die; print \"ready\\n\"; sleep 300;",
            lease.lockFileURL.path,
        ]
        lockHolder.standardOutput = readyPipe
        lockHolder.standardError = readyPipe
        try lockHolder.run()
        defer {
            if lockHolder.isRunning {
                _ = kill(lockHolder.processIdentifier, SIGKILL)
                lockHolder.waitUntilExit()
            }
        }
        let ready = try #require(try readyPipe.fileHandleForReading.read(upToCount: 6))
        #expect(String(data: ready, encoding: .utf8) == "ready\n")

        let restarted = try await RecordingStore.onDisk(url: fixture.databaseURL)
        do {
            _ = try await restarted.resumeHostMode(
                expectedLibraryID: fixture.libraryID,
                hostAuthorityID: fixture.authorityID,
                hostStateID: fixture.stateID,
                waitForLock: false
            )
            Issue.record("The inherited live descriptor must retain the writer lock")
        } catch let error as StoreError {
            #expect(error == .writerLeaseUnavailable)
        }

        _ = kill(lockHolder.processIdentifier, SIGKILL)
        lockHolder.waitUntilExit()
        #expect(lockHolder.terminationReason == .uncaughtSignal)
        #expect(lockHolder.terminationStatus == SIGKILL)

        do {
            _ = try await restarted.fetchAll()
            Issue.record("Standalone reads must fail closed on a stale Host marker")
        } catch let error as StoreError {
            #expect(error == .staleHostWriterMarker)
        }

        do {
            _ = try await restarted.upsert(
                Recording(
                    wavPath: fixture.root.appendingPathComponent("must-not-write.wav").path,
                    startedAt: startedAt
                )
            )
            Issue.record("Standalone mutation must fail closed on a stale Host marker")
        } catch let error as StoreError {
            #expect(error == .staleHostWriterMarker)
        }

        do {
            _ = try await restarted.resumeHostMode(
                expectedLibraryID: fixture.libraryID,
                hostAuthorityID: fixture.authorityID,
                hostStateID: .random(),
                waitForLock: false
            )
            Issue.record("Host recovery must reject a mismatched state ID")
        } catch let error as StoreError {
            #expect(error == .hostWriterTupleMismatch)
        }

        let resumed = try await restarted.resumeHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID,
            waitForLock: false
        )
        #expect(resumed.identity.libraryID == fixture.libraryID)
        try await restarted.disableHostMode(resumed)
    }

    @Test("Host recovery installs its lease before running a pending migration")
    func recoveryFactoryMigratesUnderHostLease() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }

        let originalLease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        try await fixture.store.abandonHostLeaseForTesting(originalLease)

        var migrator = DatabaseMigrator.harcMigrator()
        migrator.registerMigration("test_pending_host_recovery") { database in
            try database.create(table: "test_pending_host_recovery") { table in
                table.column("id", .integer).primaryKey()
            }
        }

        do {
            _ = try RecordingStore.onDiskForTesting(
                url: fixture.databaseURL,
                migrator: migrator
            )
            Issue.record("Standalone open must not migrate a Host-marked database")
        } catch let error as StoreError {
            #expect(error == .staleHostWriterMarker)
        }

        do {
            _ = try RecordingStore.recoverHostModeForTesting(
                onDiskAt: fixture.databaseURL,
                expectedLibraryID: fixture.libraryID,
                hostAuthorityID: fixture.authorityID,
                hostStateID: .random(),
                waitForLock: false,
                migrator: migrator
            )
            Issue.record("Recovery must reject an independently supplied tuple mismatch")
        } catch let error as StoreError {
            #expect(error == .hostWriterTupleMismatch)
        }

        let markerAfterFailure = try DatabaseQueue(path: fixture.databaseURL.path)
            .unsafeRead { database in
                try String.fetchOne(
                    database,
                    sql: "SELECT writer_mode FROM library_metadata WHERE id = 1"
                )
            }
        #expect(markerAfterFailure == "host")

        let recovered = try RecordingStore.recoverHostModeForTesting(
            onDiskAt: fixture.databaseURL,
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID,
            waitForLock: false,
            migrator: migrator
        )
        let recoveredMetadata = try await recovered.store.libraryMetadata()
        #expect(recoveredMetadata.writerMode == .host)
        #expect(recovered.lease.identity.libraryID == fixture.libraryID)
        let pendingMigrationApplied = try await recovered.store.dbReader.read { database in
            try database.tableExists("test_pending_host_recovery")
        }
        #expect(pendingMigrationApplied)

        try await recovered.store.disableHostMode(recovered.lease)
    }

    @Test("Canonical remote commit is atomic, exact-time, and replay idempotent")
    func canonicalCommitAndReplay() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        let capability = lease.canonicalCommitCapability

        let audioURL = try makeAudio(named: "canonical-a.wav", in: fixture.root)
        let request = try makeRequest(audioURL: audioURL)
        let first = try await fixture.store.commitCanonicalRemoteRecording(
            request,
            using: capability
        )
        #expect(first.canonicalID == request.canonicalID)
        #expect(first.revision == .initial)
        #expect(first.changeCursor.rawValue == 1)
        #expect(!first.replayed)
        #expect(first.durableCommitUnixMilliseconds > 0)
        #expect(
            first.durableCommitTime
                == Date(
                    timeIntervalSince1970:
                        Double(first.durableCommitUnixMilliseconds) / 1_000
                )
        )

        let stored = try #require(
            try await fixture.store.fetch(canonicalID: request.canonicalID)
        )
        #expect(stored.originID == request.originID)
        #expect(stored.canonicalPCMHash == request.canonicalPCMHash)
        #expect(stored.canonicalPCMFrames == request.canonicalPCMFrames)
        #expect(stored.processing == .pending)
        #expect(stored.projection == .pending)
        #expect(stored.revision == .initial)
        #expect(try await fixture.store.libraryChanges(after: .zero).count == 1)
        #expect(
            try await fixture.store.hostProcessingBacklog()
                .map(\.canonicalID) == [request.canonicalID]
        )

        let replay = try await fixture.store.commitCanonicalRemoteRecording(
            request,
            using: capability
        )
        #expect(replay.replayed)
        #expect(replay.canonicalID == first.canonicalID)
        #expect(replay.revision == first.revision)
        #expect(replay.changeCursor == first.changeCursor)
        #expect(replay.durableCommitTime == first.durableCommitTime)
        #expect(
            replay.durableCommitUnixMilliseconds
                == first.durableCommitUnixMilliseconds
        )
        #expect(try await fixture.store.libraryChanges(after: .zero).count == 1)

        try await fixture.store.updateProcessing(
            id: try #require(stored.id),
            descriptor: .ready
        )
        #expect(try await fixture.store.hostProcessingBacklog().isEmpty)
        let replayAfterProcessing = try await fixture.store
            .commitCanonicalRemoteRecording(request, using: capability)
        #expect(replayAfterProcessing.revision == .initial)
        #expect(replayAfterProcessing.changeCursor == first.changeCursor)
        #expect(replayAfterProcessing.durableCommitTime == first.durableCommitTime)

        let conflictingHash = try CanonicalPCMHash(Data(repeating: 0x44, count: 32))
        let conflictingReplay = try HostCanonicalRecordingCommitRequest(
            canonicalID: request.canonicalID,
            originID: request.originID,
            canonicalPCMHash: conflictingHash,
            canonicalPCMFrames: request.canonicalPCMFrames,
            canonicalWAVURL: request.canonicalWAVURL,
            artifactIdentity: request.artifactIdentity,
            startedAt: request.startedAt,
            endedAt: request.endedAt
        )
        do {
            _ = try await fixture.store.commitCanonicalRemoteRecording(
                conflictingReplay,
                using: capability
            )
            Issue.record("A replay cannot change its canonical PCM binding")
        } catch let error as StoreError {
            #expect(error == .originIdentityConflict)
        }

        #expect(try await fixture.store.libraryChanges(after: .zero).count == 2)
        try await fixture.store.disableHostMode(lease)

        do {
            _ = try await fixture.store.commitCanonicalRemoteRecording(
                request,
                using: capability
            )
            Issue.record("A disabled Host capability must not authorize commits")
        } catch let error as StoreError {
            #expect(error == .hostWriterCapabilityRequired)
        }
    }

    @Test("Canonical replay preserves exact milliseconds across GRDB date round-trips")
    func canonicalReplayUsesMillisecondTimeIdentity() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        let audioURL = try makeAudio(named: "millisecond-replay.wav", in: fixture.root)
        let startedAt = Date(timeIntervalSince1970: 1_785_745_998.548)
        let endedAt = Date(timeIntervalSince1970: 1_785_745_999.548)
        let request = try HostCanonicalRecordingCommitRequest(
            canonicalID: .random(),
            originID: makeOrigin(byte: 0x67),
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 0x22, count: 32)),
            canonicalPCMFrames: 48_000,
            canonicalWAVURL: audioURL,
            artifactIdentity: try artifactIdentity(for: audioURL),
            startedAt: startedAt,
            endedAt: endedAt
        )
        let first = try await fixture.store.commitCanonicalRemoteRecording(
            request,
            using: lease.canonicalCommitCapability
        )

        try await fixture.store.abandonHostLeaseForTesting(lease)
        let recovered = try await RecordingStore.recoverHostMode(
            onDiskAt: fixture.databaseURL,
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID,
            waitForLock: false
        )
        let replay = try await recovered.store.commitCanonicalRemoteRecording(
            request,
            using: recovered.lease.canonicalCommitCapability
        )
        #expect(replay.replayed)
        #expect(replay.changeCursor == first.changeCursor)
        #expect(replay.durableCommitTime == first.durableCommitTime)

        let shiftedRequest = try HostCanonicalRecordingCommitRequest(
            canonicalID: request.canonicalID,
            originID: request.originID,
            canonicalPCMHash: request.canonicalPCMHash,
            canonicalPCMFrames: request.canonicalPCMFrames,
            canonicalWAVURL: request.canonicalWAVURL,
            artifactIdentity: request.artifactIdentity,
            startedAt: request.startedAt.addingTimeInterval(0.001),
            endedAt: request.endedAt
        )
        do {
            _ = try await recovered.store.commitCanonicalRemoteRecording(
                shiftedRequest,
                using: recovered.lease.canonicalCommitCapability
            )
            Issue.record("A replay cannot change its capture time by one millisecond")
        } catch let error as StoreError {
            #expect(error == .originIdentityConflict)
        }

        try await recovered.store.disableHostMode(recovered.lease)
    }

    @Test("Canonical commit rejects unlinked, replaced, and in-place-mutated WAV bindings")
    func canonicalArtifactBindingCannotChangeBeforeCommit() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        let capability = lease.canonicalCommitCapability

        func expectRejected(
            _ request: HostCanonicalRecordingCommitRequest,
            reason: String
        ) async throws {
            do {
                _ = try await fixture.store.commitCanonicalRemoteRecording(
                    request,
                    using: capability
                )
                Issue.record("Canonical commit accepted a \(reason) artifact binding")
            } catch let error as StoreError {
                #expect(error == .canonicalArtifactIdentityMismatch)
            }
            #expect(try await fixture.store.fetch(canonicalID: request.canonicalID) == nil)
            #expect(try await fixture.store.libraryChanges(after: .zero).isEmpty)
        }

        let unlinkedURL = try makeAudio(named: "unlinked-before-commit.wav", in: fixture.root)
        let unlinkedRequest = try makeRequest(
            originID: makeOrigin(byte: 0x61),
            audioURL: unlinkedURL
        )
        try FileManager.default.removeItem(at: unlinkedURL)
        try await expectRejected(unlinkedRequest, reason: "missing")

        let replacedURL = try makeAudio(named: "replaced-before-commit.wav", in: fixture.root)
        let replacedRequest = try makeRequest(
            originID: makeOrigin(byte: 0x62),
            audioURL: replacedURL
        )
        try FileManager.default.removeItem(at: replacedURL)
        try Data(repeating: 0x55, count: 64).write(to: replacedURL, options: .atomic)
        try await expectRejected(replacedRequest, reason: "replacement-inode")

        let mutatedURL = try makeAudio(named: "mutated-before-commit.wav", in: fixture.root)
        let mutatedRequest = try makeRequest(
            originID: makeOrigin(byte: 0x63),
            audioURL: mutatedURL
        )
        let mutationDescriptor = open(
            mutatedURL.path,
            O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard mutationDescriptor >= 0 else {
            throw StoreError.invalidData("Could not open in-place mutation fixture")
        }
        var replacementByte: UInt8 = 0x31
        let mutationResult = pwrite(mutationDescriptor, &replacementByte, 1, 0)
        let synchronizationResult = fsync(mutationDescriptor)
        _ = Darwin.close(mutationDescriptor)
        guard mutationResult == 1, synchronizationResult == 0 else {
            throw StoreError.invalidData("Could not mutate canonical artifact fixture")
        }
        try await expectRejected(mutatedRequest, reason: "same-inode in-place mutation")

        try await fixture.store.disableHostMode(lease)
    }

    @Test("Generic upsert cannot rewrite remote signed provenance across recovery")
    func genericUpsertPreservesRemoteProvenance() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        let request = try makeRequest(
            audioURL: try makeAudio(named: "immutable-provenance.wav", in: fixture.root)
        )
        let originalCommit = try await fixture.store.commitCanonicalRemoteRecording(
            request,
            using: lease.canonicalCommitCapability
        )
        var attemptedRewrite = try #require(
            try await fixture.store.fetch(canonicalID: request.canonicalID)
        )
        attemptedRewrite.canonicalID = .random()
        attemptedRewrite.originID = makeOrigin(byte: 0x71)
        attemptedRewrite.canonicalPCMHash = try CanonicalPCMHash(
            Data(repeating: 0x72, count: 32)
        )
        attemptedRewrite.canonicalPCMFrames = 7
        attemptedRewrite.startedAt = request.startedAt.addingTimeInterval(3_600)
        attemptedRewrite.endedAt = nil
        attemptedRewrite.processing = .ready
        attemptedRewrite.projection = .readyV1
        attemptedRewrite.title = "Allowed local enrichment"

        let updated = try await fixture.store.upsert(attemptedRewrite)
        #expect(updated.canonicalID == request.canonicalID)
        #expect(updated.originID == request.originID)
        #expect(updated.canonicalPCMHash == request.canonicalPCMHash)
        #expect(updated.canonicalPCMFrames == request.canonicalPCMFrames)
        #expect(updated.startedAt == request.startedAt)
        #expect(updated.endedAt == request.endedAt)
        #expect(updated.processing == .pending)
        #expect(updated.projection == .pending)
        #expect(updated.title == "Allowed local enrichment")

        try await fixture.store.abandonHostLeaseForTesting(lease)
        let recovered = try await RecordingStore.recoverHostMode(
            onDiskAt: fixture.databaseURL,
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID,
            waitForLock: false
        )
        let replay = try await recovered.store.commitCanonicalRemoteRecording(
            request,
            using: recovered.lease.canonicalCommitCapability
        )
        #expect(replay.replayed)
        #expect(replay.canonicalID == originalCommit.canonicalID)
        #expect(replay.revision == originalCommit.revision)
        #expect(replay.changeCursor == originalCommit.changeCursor)
        #expect(replay.durableCommitTime == originalCommit.durableCommitTime)
        #expect(
            replay.durableCommitUnixMilliseconds
                == originalCommit.durableCommitUnixMilliseconds
        )

        try await recovered.store.disableHostMode(recovered.lease)
    }

    @Test("Canonical commit rejects duplicate IDs, paths, zero, and overflow")
    func canonicalCommitConflictsAndBounds() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let lease = try await fixture.store.enableHostMode(
            expectedLibraryID: fixture.libraryID,
            hostAuthorityID: fixture.authorityID,
            hostStateID: fixture.stateID
        )
        let capability = lease.canonicalCommitCapability
        let firstURL = try makeAudio(named: "first.wav", in: fixture.root)
        let firstRequest = try makeRequest(audioURL: firstURL)
        _ = try await fixture.store.commitCanonicalRemoteRecording(
            firstRequest,
            using: capability
        )

        let secondURL = try makeAudio(named: "second.wav", in: fixture.root)
        let duplicateID = try makeRequest(
            canonicalID: firstRequest.canonicalID,
            originID: makeOrigin(byte: 0x12),
            audioURL: secondURL
        )
        do {
            _ = try await fixture.store.commitCanonicalRemoteRecording(
                duplicateID,
                using: capability
            )
            Issue.record("A canonical ID cannot bind to a second origin")
        } catch let error as StoreError {
            #expect(error == .canonicalRecordingIdentityConflict)
        }

        let duplicatePath = try makeRequest(
            canonicalID: .random(),
            originID: makeOrigin(byte: 0x13),
            audioURL: firstURL
        )
        do {
            _ = try await fixture.store.commitCanonicalRemoteRecording(
                duplicatePath,
                using: capability
            )
            Issue.record("A canonical path cannot bind to a second origin")
        } catch let error as StoreError {
            #expect(error == .canonicalRecordingPathConflict)
        }
        #expect(try await fixture.store.libraryChanges(after: .zero).count == 1)

        let zeroUUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        do {
            _ = try HostCanonicalRecordingCommitRequest(
                canonicalID: CanonicalRecordingID(zeroUUID),
                originID: makeOrigin(byte: 0x14),
                canonicalPCMHash: try CanonicalPCMHash(Data(repeating: 0x22, count: 32)),
                canonicalPCMFrames: 1,
                canonicalWAVURL: secondURL,
                artifactIdentity: try artifactIdentity(for: secondURL),
                startedAt: startedAt,
                endedAt: nil
            )
            Issue.record("Zero canonical ID must be rejected")
        } catch let error as StoreError {
            guard case .invalidData = error else {
                Issue.record("Unexpected zero-ID error: \(error)")
                return
            }
        }

        do {
            _ = try HostCanonicalRecordingCommitRequest(
                canonicalID: .random(),
                originID: makeOrigin(byte: 0x15),
                canonicalPCMHash: try CanonicalPCMHash(Data(repeating: 0x22, count: 32)),
                canonicalPCMFrames: UInt64.max,
                canonicalWAVURL: secondURL,
                artifactIdentity: try artifactIdentity(for: secondURL),
                startedAt: startedAt,
                endedAt: nil
            )
            Issue.record("Overflowing frame count must be rejected")
        } catch let error as StoreError {
            guard case .invalidData = error else {
                Issue.record("Unexpected overflow error: \(error)")
                return
            }
        }

        let overflowURL = try makeAudio(named: "overflow-cursor.wav", in: fixture.root)
        let overflowRequest = try makeRequest(
            originID: makeOrigin(byte: 0x16),
            audioURL: overflowURL
        )
        let rawDatabase = try DatabaseQueue(path: fixture.databaseURL.path)
        try await rawDatabase.write { database in
            try database.execute(
                sql: "UPDATE library_metadata SET current_change_cursor = ? WHERE id = 1",
                arguments: [Int64.max]
            )
        }
        do {
            _ = try await fixture.store.commitCanonicalRemoteRecording(
                overflowRequest,
                using: capability
            )
            Issue.record("An exhausted change cursor must reject canonical commit")
        } catch let error as StoreError {
            #expect(error == .changeCursorOverflow)
        }

        try await fixture.store.disableHostMode(lease)
    }

    @Test("Writer path rejects unsafe parents and symlink lock files")
    func unsafeLeasePaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-writer-unsafe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard chmod(root.path, 0o777) == 0 else {
            throw StoreError.invalidData("Could not prepare unsafe directory fixture")
        }
        do {
            _ = try await RecordingStore.onDisk(url: root.appendingPathComponent("Harc.db"))
            Issue.record("Group/world-writable database parent must be rejected")
        } catch let error as StoreError {
            guard case .unsafeWriterLeasePath = error else {
                Issue.record("Unexpected unsafe-parent error: \(error)")
                return
            }
        }

        guard chmod(root.path, 0o700) == 0 else {
            throw StoreError.invalidData("Could not restore fixture permissions")
        }
        let store = try await RecordingStore.onDisk(url: root.appendingPathComponent("Harc.db"))
        let metadata = try await store.libraryMetadata()
        let target = root.appendingPathComponent("not-a-lock")
        try Data([0x01]).write(to: target)
        let lockPath = root.appendingPathComponent("Harc.db.writer.lock")
        if FileManager.default.fileExists(atPath: lockPath.path) {
            try FileManager.default.removeItem(at: lockPath)
        }
        try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: target)
        do {
            _ = try await store.enableHostMode(
                expectedLibraryID: metadata.libraryID,
                hostAuthorityID: try HostAuthorityID(Data(repeating: 0x51, count: 32)),
                hostStateID: .random(),
                waitForLock: false
            )
            Issue.record("A symlink writer lock must be rejected")
        } catch let error as StoreError {
            guard case .unsafeWriterLeasePath = error else {
                Issue.record("Unexpected symlink-lock error: \(error)")
                return
            }
        }
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harc-host-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard chmod(root.path, 0o700) == 0 else {
            throw StoreError.invalidData("Could not restrict test directory")
        }
        let databaseURL = root.appendingPathComponent("Harc.db")
        let store = try await RecordingStore.onDisk(url: databaseURL)
        let libraryID = try await store.libraryMetadata().libraryID
        return Fixture(
            root: root,
            databaseURL: databaseURL,
            store: store,
            libraryID: libraryID,
            authorityID: try HostAuthorityID(Data(repeating: 0x51, count: 32)),
            stateID: .random()
        )
    }

    private func makeAudio(named name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x7f, count: 64).write(to: url, options: .atomic)
        return url
    }

    private func makeOrigin(byte: UInt8 = 0x11) -> OriginRecordingID {
        OriginRecordingID(
            deviceID: try! DeviceID(Data(repeating: byte, count: 32)),
            recordingUUID: UUID()
        )
    }

    private func makeRequest(
        canonicalID: CanonicalRecordingID = .random(),
        originID: OriginRecordingID? = nil,
        audioURL: URL
    ) throws -> HostCanonicalRecordingCommitRequest {
        try HostCanonicalRecordingCommitRequest(
            canonicalID: canonicalID,
            originID: originID ?? makeOrigin(),
            canonicalPCMHash: CanonicalPCMHash(Data(repeating: 0x22, count: 32)),
            canonicalPCMFrames: 48_000,
            canonicalWAVURL: audioURL,
            artifactIdentity: try artifactIdentity(for: audioURL),
            startedAt: startedAt.addingTimeInterval(0.000_432),
            endedAt: startedAt.addingTimeInterval(1.000_876)
        )
    }

    private func artifactIdentity(for url: URL) throws -> HostCanonicalArtifactIdentity {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StoreError.invalidData("Could not open canonical artifact fixture")
        }
        defer { _ = Darwin.close(descriptor) }
        return try HostCanonicalArtifactIdentity(
            validatingOpenFileDescriptor: descriptor,
            boundTo: url
        )
    }
}

private struct Fixture {
    let root: URL
    let databaseURL: URL
    let store: RecordingStore
    let libraryID: LibraryID
    let authorityID: HostAuthorityID
    let stateID: HostStateID

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
