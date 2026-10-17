import XCTest
import HarcDomain
@testable import HarcStore

final class PeopleStoreTests: XCTestCase {
    func test_publishedRecognitionPackSurvivesReopenAndRenewsAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.db")
        let store = try await RecordingStore.onDisk(url: url)
        let person = try await store.createPerson(displayName: "Alice")
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await store.publishedSpeakerRecognitionPack(at: time)
        let repeated = try await store.publishedSpeakerRecognitionPack(at: time.addingTimeInterval(60))
        XCTAssertEqual(repeated, first)
        let reopened = try await RecordingStore.onDisk(url: url)
        let durable = try await reopened.publishedSpeakerRecognitionPack(at: first.expiresAt.addingTimeInterval(-1))
        XCTAssertEqual(durable, first)
        let database = await reopened.uncoordinatedDB
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_pack_renewal BEFORE UPDATE ON published_speaker_recognition_pack
                BEGIN SELECT RAISE(ABORT, 'injected publication failure'); END
                """)
        }
        do {
            _ = try await reopened.publishedSpeakerRecognitionPack(at: first.expiresAt)
            XCTFail("Failed publication must not advance the revision")
        } catch {}
        let unchanged = try await reopened.speakerRecognitionPack(at: time)
        XCTAssertEqual(unchanged.revision, first.revision)
        try await database.write { db in
            try db.execute(sql: "DROP TRIGGER reject_pack_renewal")
        }
        let renewed = try await reopened.publishedSpeakerRecognitionPack(at: first.expiresAt)
        XCTAssertGreaterThan(renewed.revision, first.revision)
        XCTAssertEqual(renewed.profiles, first.profiles)
        XCTAssertEqual(renewed.generatedAt, first.expiresAt)
        XCTAssertGreaterThan(renewed.expiresAt, first.expiresAt)
        let otherConnection = try await store.publishedSpeakerRecognitionPack(at: first.expiresAt.addingTimeInterval(1))
        XCTAssertEqual(otherConnection, renewed)
        try await store.updatePersonThreshold(personID: person, threshold: 0.8)
        let edited = try await reopened.publishedSpeakerRecognitionPack(at: first.expiresAt.addingTimeInterval(2))
        XCTAssertGreaterThan(edited.revision, renewed.revision)
        XCTAssertEqual(edited.profiles[0].matchThreshold, 0.8)
    }

    func test_thresholdChangesPublishNewRecognitionRevisionAndRollbackTogether() async throws {
        let store = try await RecordingStore.inMemory()
        let personID = try await store.createPerson(displayName: "Alice")
        let packTime = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try await store.speakerRecognitionPack(at: packTime)
        try await store.updatePersonThreshold(personID: personID, threshold: 0.8)
        let updated = try await store.speakerRecognitionPack(at: packTime)
        XCTAssertGreaterThan(updated.revision, original.revision)
        XCTAssertGreaterThan(updated.profiles[0].revision, original.profiles[0].revision)
        XCTAssertEqual(updated.profiles[0].matchThreshold, 0.8)

        let database = await store.uncoordinatedDB
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_threshold_pack BEFORE UPDATE ON speaker_identity_metadata
                BEGIN SELECT RAISE(ABORT, 'injected pack failure'); END
                """)
        }
        do {
            try await store.updatePersonThreshold(personID: personID, threshold: 0.9)
            XCTFail("A failed pack revision must fail the threshold save")
        } catch {}
        let failed = try await store.speakerRecognitionPack(at: packTime)
        XCTAssertEqual(failed, updated)
        try await database.write { db in
            try db.execute(sql: "DROP TRIGGER reject_threshold_pack")
        }
        for invalid in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            do {
                try await store.updatePersonThreshold(personID: personID, threshold: invalid)
                XCTFail("Invalid thresholds must not corrupt the recognition pack")
            } catch {}
        }
        do {
            try await store.updatePersonThreshold(personID: -1, threshold: 0.8)
            XCTFail("A deleted person must not report a successful save")
        } catch { XCTAssertEqual(error as? StoreError, .notFound) }
        let unchanged = try await store.speakerRecognitionPack(at: packTime)
        XCTAssertEqual(unchanged, updated)
        try await store.updatePersonThreshold(personID: personID, threshold: nil)
        let reset = try await store.speakerRecognitionPack(at: packTime)
        XCTAssertGreaterThan(reset.revision, updated.revision)
        XCTAssertGreaterThan(reset.profiles[0].revision, updated.profiles[0].revision)
        XCTAssertEqual(reset.profiles[0].matchThreshold, original.profiles[0].matchThreshold)
    }

    func test_shortConfirmedEvidenceRetainsNameButCannotEnrollLocallyOrRemotely() async throws {
        for remote in [false, true] {
            for duration in [4_999, 5_000] {
                let store = try await RecordingStore.inMemory()
                let referenceID = try await seedRecording(in: store, wav: "/tmp/enrollment-reference.wav")
                let queryID = try await seedRecording(in: store, wav: "/tmp/enrollment-query.wav")
                let personID = try await store.createPerson(displayName: "Alice")
                let vector = [Float](repeating: 0.0625, count: 256)
                let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
                if remote {
                    let reference = try await store.fetch(id: referenceID)
                    let observation = try SpeakerEmbeddingObservation(operationID: .random(),
                        canonicalRecordingID: XCTUnwrap(reference).canonicalID, speakerIndex: 0,
                        embedding: RecordingStore.quantizeSpeakerEmbedding(vector), modelID: "wespeaker_v2",
                        speechDurationMs: UInt64(duration), segmentCount: 1)
                    _ = try await store.submitSpeakerObservation(observation, from: source)
                } else {
                    try await store.upsertSpeakerEmbeddings(recordingID: referenceID, rows: [
                        .init(recordingID: referenceID, speakerIndex: 0, embedding: encodeFloat32(vector),
                              segmentCount: 1, totalMs: duration, embedderKind: "wespeaker_v2")])
                }
                try await store.linkSpeaker(personID: personID, recordingID: referenceID, speakerIndex: 0)
                try await store.updateSpeakerNames(id: referenceID, names: [0: "Alice"])
                let named = try await store.fetch(id: referenceID)
                XCTAssertEqual(named?.speakerNames[0], "Alice")
                let links = try await store.fetchPersonSpeakerLinks(recordingID: referenceID)
                XCTAssertEqual(links.first?.personID, personID)
                XCTAssertEqual(links.first?.isUserConfirmed, true)
                let pack = try await store.speakerRecognitionPack()
                XCTAssertEqual(pack.profiles.first?.prototypes.count, duration == 5_000 ? 1 : 0)
                let query = try await store.fetch(id: queryID)
                let observation = try SpeakerEmbeddingObservation(operationID: .random(),
                    canonicalRecordingID: XCTUnwrap(query).canonicalID, speakerIndex: 0,
                    embedding: RecordingStore.quantizeSpeakerEmbedding(vector), modelID: "wespeaker_v2",
                    speechDurationMs: 9_000, segmentCount: 1)
                let decision = try await store.submitSpeakerObservation(observation, from: source)
                XCTAssertEqual(decision.displayName, duration == 5_000 ? "Alice" : nil)
            }
        }
    }


    func test_recordingEmbeddingFetch_preservesModelsAndLegacyRowsWithoutOtherRecordings() async throws {
        let store = try await RecordingStore.inMemory()
        let first = try await seedRecording(in: store, wav: "/tmp/model-first.wav")
        let second = try await seedRecording(in: store, wav: "/tmp/model-second.wav")
        for recordingID in [first, second] {
            try await store.upsertSpeakerEmbeddings(recordingID: recordingID, rows:
                ["wespeaker_v2", "ecapa-test", nil].enumerated().map { index, model in
                    .init(recordingID: recordingID, speakerIndex: index,
                          embedding: encodeFloat32([Float(index + 1)]),
                          segmentCount: index + 1, totalMs: 2_000 + index,
                          embedderKind: model)
                }
            )
        }
        let rows = try await store.fetchSpeakerEmbeddings(recordingID: first)
        XCTAssertEqual(rows.map(\.recordingID), [first, first, first])
        XCTAssertEqual(rows.map(\.speakerIndex), [0, 1, 2])
        XCTAssertEqual(rows.map(\.embedderKind), ["wespeaker_v2", "ecapa-test", nil])
        XCTAssertEqual(rows.map(\.totalMs), [2_000, 2_001, 2_002])
        XCTAssertEqual(rows.map(\.embedding), [1, 2, 3].map { encodeFloat32([Float($0)]) })
        let legacyModel = try await store.fetchSpeakerEmbeddings(recordingID: first, embedderKind: "wespeaker_v2")
        XCTAssertEqual(legacyModel.map(\.speakerIndex), [0])
        let absentModel = try await store.fetchSpeakerEmbeddings(recordingID: first, embedderKind: "absent")
        XCTAssertTrue(absentModel.isEmpty)
    }

    // MARK: - Group A: createPerson + fetchPeople

    func test_createAndFetchPerson_roundTrip() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await store.createPerson(displayName: "Sarah")
        XCTAssertGreaterThan(id, 0)

        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].displayName, "Sarah")
        XCTAssertNil(people[0].matchThreshold)
        XCTAssertEqual(people[0].id, id)
    }

    // MARK: - Group B: renamePerson + deletePerson

    func test_renamePerson_updatesNameAndTimestamp() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await store.createPerson(displayName: "Sarah")
        let original = try await store.fetchPeople()[0]
        try await Task.sleep(nanoseconds: 50_000_000)
        try await store.renamePerson(id: id, to: "Sarah B.")
        let updated = try await store.fetchPeople()[0]
        XCTAssertEqual(updated.displayName, "Sarah B.")
        XCTAssertGreaterThan(updated.updatedAt, original.updatedAt)
    }

    func test_deletePerson_removesRow() async throws {
        let store = try await RecordingStore.inMemory()
        let id = try await store.createPerson(displayName: "Sarah")
        try await store.deletePerson(id: id)
        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 0)
    }

    // MARK: - fetchPersonStats

    /// Regression: `started_at` is a GRDB .datetime TEXT column; the stats
    /// query used to decode MIN/MAX of it `as Double?`, which traps inside
    /// GRDB's `try!` for any person with at least one linked recording.
    /// The zero-link case returned NULL aggregates and survived, which is
    /// exactly why no earlier test caught it.
    func test_fetchPersonStats_withLinkedRecording_doesNotTrapAndReturnsBounds() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/stats.wav")
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 0)

        let stats = try await store.fetchPersonStats(personID: personID)
        XCTAssertEqual(stats.recordingCount, 1)
        XCTAssertNotNil(stats.firstSeen)
        XCTAssertNotNil(stats.lastSeen)
    }

    // MARK: - Group C: linkSpeaker + unlinkSpeaker + fetchPersonSpeakerLinks

    func test_linkSpeaker_writesPersonSpeakersRow() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 1)
        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].personID, personID)
        XCTAssertEqual(links[0].speakerIndex, 1)
    }

    func test_linkSpeaker_replacesExistingLinkInSameSlot() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")
        try await store.linkSpeaker(personID: sarah, recordingID: recID, speakerIndex: 0)
        try await store.linkSpeaker(personID: david, recordingID: recID, speakerIndex: 0)
        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].personID, david)
    }

    func test_unlinkSpeaker_removesRow() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 0)
        try await store.unlinkSpeaker(recordingID: recID, speakerIndex: 0)
        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 0)
    }

    // MARK: - Group D: resolvedSpeakerName

    func test_resolvedSpeakerName_personLinkWins() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        try await store.updateSpeakerNames(id: recID, names: [0: "Old fallback"])
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recID, speakerIndex: 0)
        let name = try await store.resolvedSpeakerName(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(name, "Sarah")
    }

    func test_resolvedSpeakerName_speakerNamesJSONFallback() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        try await store.updateSpeakerNames(id: recID, names: [0: "Free-text Bob"])
        let name = try await store.resolvedSpeakerName(recordingID: recID, speakerIndex: 0)
        XCTAssertEqual(name, "Free-text Bob")
    }

    func test_resolvedSpeakerName_defaultFallback() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let name = try await store.resolvedSpeakerName(recordingID: recID, speakerIndex: 2)
        XCTAssertEqual(name, "Speaker 3")
    }

    // MARK: - Phase 2.5: suggestion CRUD

    func test_insertAndFetchPendingSuggestion() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")

        try await store.insertPendingSuggestion(personID: personID, recordingID: recID, speakerIndex: 0, score: 0.82)
        let perPerson = try await store.fetchPendingSuggestions(personID: personID)
        XCTAssertEqual(perPerson.count, 1)
        XCTAssertEqual(perPerson[0].score, 0.82, accuracy: 0.001)

        let perRecording = try await store.fetchPendingSuggestionsForRecording(recID)
        XCTAssertEqual(perRecording.count, 1)
        XCTAssertEqual(perRecording[0].personID, personID)
    }

    func test_confirmSuggestion_writesLinkAndClearsAllSuggestionsForSlot() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")

        try await store.insertPendingSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0, score: 0.82)
        try await store.insertPendingSuggestion(personID: david, recordingID: recID, speakerIndex: 0, score: 0.71)

        try await store.confirmSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0)

        let links = try await store.fetchPersonSpeakerLinks(recordingID: recID)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].personID, sarah)
        let remaining = try await store.fetchPendingSuggestionsForRecording(recID)
        XCTAssertEqual(remaining.count, 0)
    }

    func test_dismissSuggestion_writesDismissalAndClearsSpecificSuggestion() async throws {
        let store = try await RecordingStore.inMemory()
        let recID = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let david = try await store.createPerson(displayName: "David")

        try await store.insertPendingSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0, score: 0.82)
        try await store.insertPendingSuggestion(personID: david, recordingID: recID, speakerIndex: 0, score: 0.71)

        try await store.dismissSuggestion(personID: sarah, recordingID: recID, speakerIndex: 0)

        let remaining = try await store.fetchPendingSuggestionsForRecording(recID)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].personID, david)
        let isDismissed = try await store.isDismissed(personID: sarah, recordingID: recID, speakerIndex: 0)
        XCTAssertTrue(isDismissed)
    }

    func test_pendingSuggestionCount() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await seedRecording(in: store, wav: "/tmp/b.wav")
        let personID = try await store.createPerson(displayName: "Sarah")

        try await store.insertPendingSuggestion(personID: personID, recordingID: recA, speakerIndex: 0, score: 0.82)
        try await store.insertPendingSuggestion(personID: personID, recordingID: recB, speakerIndex: 1, score: 0.79)

        let count = try await store.pendingSuggestionCount(personID: personID)
        XCTAssertEqual(count, 2)
    }

    // MARK: - Phase 2.6: mergePeople + splitEmbeddings

    func test_mergePeople_movesLinksAndSuggestionsAndDeletesSource() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        let sarahB = try await store.createPerson(displayName: "Sarah B")

        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: sarahB, recordingID: recB, speakerIndex: 1)
        try await store.insertPendingSuggestion(personID: sarahB, recordingID: recA, speakerIndex: 1, score: 0.7)

        try await store.mergePeople(sourceIDs: [sarahB], into: sarah)

        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].id, sarah)

        let linksB = try await store.fetchPersonSpeakerLinks(recordingID: recB)
        XCTAssertEqual(linksB.count, 1)
        XCTAssertEqual(linksB[0].personID, sarah)

        let suggestions = try await store.fetchPendingSuggestions(personID: sarah)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].recordingID, recA)
    }

    func test_splitEmbeddings_movesSelectedSlotsToNewPerson() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let recB = try await seedRecording(in: store, wav: "/tmp/b.wav")
        let sarah = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: sarah, recordingID: recA, speakerIndex: 0)
        try await store.linkSpeaker(personID: sarah, recordingID: recB, speakerIndex: 0)

        try await store.insertPendingSuggestion(personID: sarah, recordingID: recB, speakerIndex: 0, score: 0.9)
        let newID = try await store.splitEmbeddings(
            slots: [(recordingID: recB, speakerIndex: 0)],
            intoNewPersonNamed: "Sarah work"
        )

        let people = try await store.fetchPeople()
        XCTAssertEqual(people.count, 2)
        XCTAssertTrue(people.contains { $0.id == newID && $0.displayName == "Sarah work" })

        let linksA = try await store.fetchPersonSpeakerLinks(recordingID: recA)
        let linksB2 = try await store.fetchPersonSpeakerLinks(recordingID: recB)
        XCTAssertEqual(linksA[0].personID, sarah)
        XCTAssertEqual(linksB2[0].personID, newID)
        let pending = try await store.fetchPendingSuggestionsForRecording(recB)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Phase 2.7: personRowItems

    func test_personRowItems_includesSuggestionCountAndLastSeen() async throws {
        let store = try await RecordingStore.inMemory()
        let recA = try await seedRecording(in: store, wav: "/tmp/a.wav")
        let personID = try await store.createPerson(displayName: "Sarah")
        try await store.linkSpeaker(personID: personID, recordingID: recA, speakerIndex: 0)
        try await store.insertPendingSuggestion(personID: personID, recordingID: recA, speakerIndex: 1, score: 0.8)

        let items = try await store.personRowItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].person.displayName, "Sarah")
        XCTAssertEqual(items[0].suggestionCount, 1)
        XCTAssertNotNil(items[0].lastSeen)
    }

    // MARK: - Host-authoritative speaker identity sync

    func test_recognitionPack_usesStablePersonAndPrototypeIdentities() async throws {
        let store = try await RecordingStore.inMemory()
        let recordingID = try await seedRecording(in: store, wav: "/tmp/pack.wav")
        let personID = try await store.createPerson(displayName: "Frank Thomas")
        try await store.linkSpeaker(
            personID: personID,
            recordingID: recordingID,
            speakerIndex: 0
        )
        let vector = [Float](repeating: 0.0625, count: 256)
        let prototypeID = SpeakerPrototypeID.random()
        try await store.upsertSpeakerEmbeddings(
            recordingID: recordingID,
            rows: [
                .init(
                    prototypeID: prototypeID,
                    recordingID: recordingID,
                    speakerIndex: 0,
                    embedding: encodeFloat32(vector),
                    segmentCount: 4,
                    totalMs: 12_000,
                    embedderKind: "wespeaker_v2"
                ),
            ]
        )

        let fetchedPeople = try await store.fetchPeople()
        let person = try XCTUnwrap(fetchedPeople.first)
        let pack = try await store.speakerRecognitionPack()

        XCTAssertEqual(pack.profiles.count, 1)
        XCTAssertEqual(pack.profiles[0].id, person.stableID)
        XCTAssertEqual(pack.profiles[0].displayName, "Frank Thomas")
        XCTAssertEqual(pack.profiles[0].prototypes.map(\.id), [prototypeID])
        XCTAssertEqual(pack.profiles[0].prototypes[0].embedding.dimensions, 256)
        XCTAssertEqual(pack.profiles[0].prototypes[0].embedding.values.count, 256)
    }

    func test_submitSpeakerObservation_hostDecisionIsCanonicalAndIdempotent() async throws {
        let store = try await RecordingStore.inMemory()
        let referenceID = try await seedRecording(in: store, wav: "/tmp/reference.wav")
        let incomingID = try await seedRecording(in: store, wav: "/tmp/incoming.wav")
        let personID = try await store.createPerson(displayName: "Frank Thomas")
        try await store.linkSpeaker(
            personID: personID,
            recordingID: referenceID,
            speakerIndex: 0
        )
        let vector = [Float](repeating: 0.0625, count: 256)
        try await store.upsertSpeakerEmbeddings(
            recordingID: referenceID,
            rows: [
                .init(
                    recordingID: referenceID,
                    speakerIndex: 0,
                    embedding: encodeFloat32(vector),
                    segmentCount: 5,
                    totalMs: 15_000,
                    embedderKind: "wespeaker_v2"
                ),
            ]
        )
        let fetchedIncoming = try await store.fetch(id: incomingID)
        let incoming = try XCTUnwrap(fetchedIncoming)
        let observation = try SpeakerEmbeddingObservation(
            operationID: .random(),
            canonicalRecordingID: incoming.canonicalID,
            speakerIndex: 0,
            embedding: RecordingStore.quantizeSpeakerEmbedding(vector),
            modelID: "wespeaker_v2",
            speechDurationMs: 9_000,
            segmentCount: 3
        )
        let sourceDevice = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))

        let first = try await store.submitSpeakerObservation(
            observation,
            from: sourceDevice
        )
        let replay = try await store.submitSpeakerObservation(
            observation,
            from: sourceDevice
        )

        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.disposition, .matched)
        XCTAssertEqual(first.displayName, "Frank Thomas")
        XCTAssertGreaterThan(first.score ?? 0, 0.99)
        let fetchedUpdated = try await store.fetch(id: incomingID)
        let updated = try XCTUnwrap(fetchedUpdated)
        XCTAssertEqual(updated.speakerNames[0], "Frank Thomas")
        XCTAssertGreaterThan(updated.revision, incoming.revision)
    }

    func test_ambiguousObservationPersistsWithoutAssigningEitherPerson() async throws {
        let store = try await RecordingStore.inMemory()
        let vector = [Float](repeating: 0.0625, count: 256)
        for name in ["Alice", "Bob"] {
            let reference = try await seedRecording(in: store, wav: "/tmp/ambiguity-\(name).wav")
            let person = try await store.createPerson(displayName: name)
            try await store.linkSpeaker(personID: person, recordingID: reference, speakerIndex: 0)
            try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
                .init(recordingID: reference, speakerIndex: 0, embedding: encodeFloat32(vector),
                      segmentCount: 5, totalMs: 15_000, embedderKind: "wespeaker_v2")
            ])
        }
        let incomingID = try await seedRecording(in: store, wav: "/tmp/ambiguity-incoming.wav")
        let fetched = try await store.fetch(id: incomingID)
        let incoming = try XCTUnwrap(fetched)
        let observation = try SpeakerEmbeddingObservation(
            operationID: .random(), canonicalRecordingID: incoming.canonicalID,
            speakerIndex: 0, embedding: RecordingStore.quantizeSpeakerEmbedding(vector),
            modelID: "wespeaker_v2", speechDurationMs: 9_000, segmentCount: 3
        )
        let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
        let decision = try await store.submitSpeakerObservation(observation, from: source)
        let replay = try await store.submitSpeakerObservation(observation, from: source)
        XCTAssertEqual(decision, replay)
        XCTAssertEqual(decision.disposition, .noMatch)
        XCTAssertNil(decision.personID)
        let updated = try await store.fetch(id: incomingID)
        XCTAssertNil(updated?.speakerNames[0])
        XCTAssertEqual(updated?.revision, incoming.revision)
    }

    func test_speakerReevaluationCannotUseItsOwnPriorObservation() async throws {
        let store = try await RecordingStore.inMemory()
        let person = try await store.createPerson(displayName: "Alice")
        let reference = try await seedRecording(in: store, wav: "/tmp/self-reference.wav")
        let incomingID = try await seedRecording(in: store, wav: "/tmp/self-incoming.wav")
        let vector = [Float](repeating: 0.0625, count: 256)
        try await store.linkSpeaker(personID: person, recordingID: reference, speakerIndex: 0)
        try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
            .init(recordingID: reference, speakerIndex: 0, embedding: encodeFloat32(vector),
                  segmentCount: 5, totalMs: 15_000, embedderKind: "wespeaker_v2")
        ])
        let fetched = try await store.fetch(id: incomingID)
        let incoming = try XCTUnwrap(fetched)
        func observation() throws -> SpeakerEmbeddingObservation {
            try SpeakerEmbeddingObservation(operationID: .random(), canonicalRecordingID: incoming.canonicalID,
                speakerIndex: 0, embedding: RecordingStore.quantizeSpeakerEmbedding(vector),
                modelID: "wespeaker_v2", speechDurationMs: 9_000, segmentCount: 3)
        }
        let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
        let original = try observation()
        let first = try await store.submitSpeakerObservation(original, from: source)
        XCTAssertEqual(first.displayName, "Alice")
        try await store.unlinkSpeaker(recordingID: reference, speakerIndex: 0)
        // Also exercise the local-copy branch of the matching union.
        try await store.upsertSpeakerEmbeddings(recordingID: incomingID, rows: [
            .init(recordingID: incomingID, speakerIndex: 0, embedding: encodeFloat32(vector),
                  segmentCount: 3, totalMs: 9_000, embedderKind: "wespeaker_v2")
        ])
        let reevaluated = try await store.submitSpeakerObservation(observation(), from: source)
        XCTAssertNil(reevaluated.displayName)
        XCTAssertEqual(reevaluated.disposition, .noMatch)
        let afterReevaluation = try await store.fetch(id: incomingID)
        let remainingLinks = try await store.fetchPersonSpeakerLinks(recordingID: incomingID)
        let remainingSuggestions = try await store.fetchPendingSuggestionsForRecording(incomingID)
        XCTAssertNil(afterReevaluation?.speakerNames[0])
        XCTAssertTrue(remainingLinks.isEmpty)
        XCTAssertTrue(remainingSuggestions.isEmpty)
        XCTAssertGreaterThan(afterReevaluation?.revision.rawValue ?? 0, first.recordingRevision.rawValue)
        let replay = try await store.submitSpeakerObservation(original, from: source)
        XCTAssertEqual(replay, first)
        let afterReplay = try await store.fetch(id: incomingID)
        XCTAssertNil(afterReplay?.speakerNames[0], "An immutable historical replay must not restore a stale name")
    }

    func test_nonmatchPreservesConfirmedAssignmentsAndEditedLabels() async throws {
        for confirmed in [false, true] {
            let store = try await RecordingStore.inMemory()
            let person = try await store.createPerson(displayName: "Alice")
            let reference = try await seedRecording(in: store, wav: "/tmp/preserved-reference.wav")
            let incomingID = try await seedRecording(in: store, wav: "/tmp/preserved-incoming.wav")
            let vector = [Float](repeating: 0.0625, count: 256)
            try await store.linkSpeaker(personID: person, recordingID: reference, speakerIndex: 0)
            try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
                .init(recordingID: reference, speakerIndex: 0, embedding: encodeFloat32(vector),
                      segmentCount: 5, totalMs: 15_000, embedderKind: "wespeaker_v2")
            ])
            let fetched = try await store.fetch(id: incomingID)
            let incoming = try XCTUnwrap(fetched)
            let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
            func submit() async throws -> SpeakerObservationDecision {
                let observation = try SpeakerEmbeddingObservation(operationID: .random(),
                    canonicalRecordingID: incoming.canonicalID, speakerIndex: 0,
                    embedding: RecordingStore.quantizeSpeakerEmbedding(vector), modelID: "wespeaker_v2",
                    speechDurationMs: 9_000, segmentCount: 3)
                return try await store.submitSpeakerObservation(observation, from: source)
            }
            let first = try await submit()
            XCTAssertEqual(first.displayName, "Alice")
            if confirmed {
                try await store.linkSpeaker(personID: person, recordingID: incomingID, speakerIndex: 0)
            } else {
                try await store.updateSpeakerNames(id: incomingID, names: [0: "My edited label"])
            }
            try await store.unlinkSpeaker(recordingID: reference, speakerIndex: 0)
            let decision = try await submit()
            XCTAssertEqual(decision.disposition, .noMatch)
            let saved = try await store.fetch(id: incomingID)
            XCTAssertEqual(saved?.speakerNames[0], confirmed ? "Alice" : "My edited label")
            let links = try await store.fetchPersonSpeakerLinks(recordingID: incomingID)
            XCTAssertEqual(links.count, confirmed ? 1 : 0)
            if confirmed { XCTAssertTrue(links[0].isUserConfirmed) }
            let suggestions = try await store.fetchPendingSuggestionsForRecording(incomingID)
            XCTAssertTrue(suggestions.isEmpty)
        }
    }

    func test_correctedRemoteSpeakerEvidenceFollowsCurrentAssignment() async throws {
        let store = try await RecordingStore.inMemory()
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let reference = try await seedRecording(in: store, wav: "/tmp/correction-reference.wav")
        let incomingID = try await seedRecording(in: store, wav: "/tmp/correction-incoming.wav")
        let vector = [Float](repeating: 0.0625, count: 256)
        try await store.linkSpeaker(personID: alice, recordingID: reference, speakerIndex: 0)
        try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
            .init(recordingID: reference, speakerIndex: 0, embedding: encodeFloat32(vector),
                  segmentCount: 5, totalMs: 15_000, embedderKind: "wespeaker_v2")
        ])
        let fetched = try await store.fetch(id: incomingID)
        let incoming = try XCTUnwrap(fetched)
        let observation = try SpeakerEmbeddingObservation(
            operationID: .random(), canonicalRecordingID: incoming.canonicalID, speakerIndex: 0,
            embedding: RecordingStore.quantizeSpeakerEmbedding(vector), modelID: "wespeaker_v2",
            speechDurationMs: 9_000, segmentCount: 3
        )
        let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
        let original = try await store.submitSpeakerObservation(observation, from: source)
        XCTAssertEqual(original.displayName, "Alice")
        try await store.unlinkSpeaker(recordingID: reference, speakerIndex: 0)
        try await store.linkSpeaker(personID: bob, recordingID: incomingID, speakerIndex: 0)
        let corrected = try await store.speakerRecognitionPack()
        XCTAssertEqual(corrected.profiles.first { $0.displayName == "Alice" }?.prototypes.count, 0)
        XCTAssertEqual(corrected.profiles.first { $0.displayName == "Bob" }?.prototypes.count, 1)
        let replay = try await store.submitSpeakerObservation(observation, from: source)
        XCTAssertEqual(replay, original) // Immutable historical decision, not new learning authority.
        let queryID = try await seedRecording(in: store, wav: "/tmp/correction-query.wav")
        let queryFetched = try await store.fetch(id: queryID)
        let query = try XCTUnwrap(queryFetched)
        let next = try SpeakerEmbeddingObservation(
            operationID: .random(), canonicalRecordingID: query.canonicalID, speakerIndex: 0,
            embedding: RecordingStore.quantizeSpeakerEmbedding(vector), modelID: "wespeaker_v2",
            speechDurationMs: 9_000, segmentCount: 3
        )
        let decision = try await store.submitSpeakerObservation(next, from: source)
        XCTAssertEqual(decision.displayName, "Bob")
        try await store.unlinkSpeaker(recordingID: incomingID, speakerIndex: 0)
        try await store.unlinkSpeaker(recordingID: queryID, speakerIndex: 0)
        let cleared = try await store.speakerRecognitionPack()
        XCTAssertTrue(cleared.profiles.allSatisfy { $0.prototypes.isEmpty })
    }

    func test_recognitionPackReservesSlotsForDistinctRecordingSpeakers() async throws {
        let store = try await RecordingStore.inMemory()
        let person = try await store.createPerson(displayName: "Alice")
        let vector = [Float](repeating: 0.0625, count: 256)
        for duration in [7_000, 8_000, 9_000] {
            let recording = try await seedRecording(in: store, wav: "/tmp/diverse-\(duration).wav")
            try await store.linkSpeaker(personID: person, recordingID: recording, speakerIndex: 0)
            try await store.upsertSpeakerEmbeddings(recordingID: recording, rows: [
                .init(recordingID: recording, speakerIndex: 0, embedding: encodeFloat32(vector),
                      segmentCount: 3, totalMs: duration, embedderKind: "wespeaker_v2")
            ])
        }
        let incomingID = try await seedRecording(in: store, wav: "/tmp/repeated-evidence.wav")
        let fetched = try await store.fetch(id: incomingID)
        let incoming = try XCTUnwrap(fetched)
        let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
        for _ in 0..<3 {
            let observation = try SpeakerEmbeddingObservation(
                operationID: .random(), canonicalRecordingID: incoming.canonicalID,
                speakerIndex: 0, embedding: RecordingStore.quantizeSpeakerEmbedding(vector),
                modelID: "wespeaker_v2", speechDurationMs: 15_000, segmentCount: 3)
            let decision = try await store.submitSpeakerObservation(observation, from: source)
            XCTAssertEqual(decision.disposition, .matched)
        }
        let inferredPack = try await store.speakerRecognitionPack()
        XCTAssertEqual(inferredPack.profiles[0].prototypes.map(\.speechDurationMs).sorted(), [7_000,8_000,9_000])
        try await store.linkSpeaker(personID: person, recordingID: incomingID, speakerIndex: 0)
        let pack = try await store.speakerRecognitionPack()
        XCTAssertEqual(pack.profiles[0].prototypes.map(\.speechDurationMs).sorted(), [8_000,9_000,15_000])
        // A local copy of the same speaker must not take another slot either.
        try await store.upsertSpeakerEmbeddings(recordingID: incomingID, rows: [
            .init(recordingID: incomingID, speakerIndex: 0, embedding: encodeFloat32(vector),
                  segmentCount: 3, totalMs: 15_000, embedderKind: "wespeaker_v2")
        ])
        let updated = try await store.speakerRecognitionPack()
        XCTAssertEqual(updated.profiles[0].prototypes.map(\.speechDurationMs).sorted(), [8_000,9_000,15_000])
    }

    func test_inferredMatchesCannotEnrollOtherRecordingsUntilConfirmed() async throws {
        let store = try await RecordingStore.inMemory()
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let reference = try await seedRecording(in: store, wav: "/tmp/trusted-reference.wav")
        let incomingID = try await seedRecording(in: store, wav: "/tmp/inferred-evidence.wav")
        let queryID = try await seedRecording(in: store, wav: "/tmp/later-query.wav")
        let vector = [Float](repeating: 0.0625, count: 256)
        try await store.linkSpeaker(personID: alice, recordingID: reference, speakerIndex: 0)
        try await store.upsertSpeakerEmbeddings(recordingID: reference, rows: [
            .init(recordingID: reference, speakerIndex: 0, embedding: encodeFloat32(vector),
                  segmentCount: 5, totalMs: 15_000, embedderKind: "wespeaker_v2")
        ])
        let source = try DeviceID(Data(repeating: 7, count: DeviceID.byteCount))
        func submit(_ id: Int64) async throws -> SpeakerObservationDecision {
            let fetched = try await store.fetch(id: id)
            let recording = try XCTUnwrap(fetched)
            return try await store.submitSpeakerObservation(.init(operationID: .random(),
                canonicalRecordingID: recording.canonicalID, speakerIndex: 0,
                embedding: RecordingStore.quantizeSpeakerEmbedding(vector), modelID: "wespeaker_v2",
                speechDurationMs: 9_000, segmentCount: 3), from: source)
        }
        let beforeAutomatic = try await store.speakerRecognitionPack()
        let initial = try await submit(incomingID)
        XCTAssertEqual(initial.displayName, "Alice")
        let afterAutomatic = try await store.speakerRecognitionPack()
        XCTAssertEqual(afterAutomatic.revision, beforeAutomatic.revision)
        let inferredLinks = try await store.fetchPersonSpeakerLinks(recordingID: incomingID)
        XCTAssertEqual(inferredLinks.first?.isUserConfirmed, false)
        let review = try await store.fetchPendingSuggestionsForRecording(incomingID)
        XCTAssertEqual(review.map(\.personID), [alice])
        try await store.upsertSpeakerEmbeddings(recordingID: incomingID, rows: [
            .init(recordingID: incomingID, speakerIndex: 0, embedding: encodeFloat32(vector),
                  segmentCount: 3, totalMs: 9_000, embedderKind: "wespeaker_v2")
        ])
        try await store.unlinkSpeaker(recordingID: reference, speakerIndex: 0)
        let pack = try await store.speakerRecognitionPack()
        XCTAssertTrue(pack.profiles.allSatisfy { $0.prototypes.isEmpty })
        let localEvidence = try await store.fetchEmbeddingsForPerson(alice, embedderKind: "wespeaker_v2")
        XCTAssertTrue(localEvidence.isEmpty)
        let unresolved = try await submit(queryID)
        XCTAssertEqual(unresolved.disposition, .noMatch)
        // Explicit correction authorizes this evidence for future recordings.
        try await store.linkSpeaker(personID: bob, recordingID: incomingID, speakerIndex: 0)
        let correctedLinks = try await store.fetchPersonSpeakerLinks(recordingID: incomingID)
        XCTAssertEqual(correctedLinks.first?.isUserConfirmed, true)
        let clearedReview = try await store.fetchPendingSuggestionsForRecording(incomingID)
        XCTAssertTrue(clearedReview.isEmpty)
        let confirmed = try await submit(queryID)
        XCTAssertEqual(confirmed.displayName, "Bob")
        let reviewID = try await seedRecording(in: store, wav: "/tmp/confirm-review.wav")
        let suggestion = try await submit(reviewID)
        XCTAssertEqual(suggestion.displayName, "Bob")
        try await store.confirmSuggestion(personID: bob, recordingID: reviewID, speakerIndex: 0)
        let firstConfirmationPack = try await store.speakerRecognitionPack()
        try await store.confirmSuggestion(personID: bob, recordingID: reviewID, speakerIndex: 0)
        let duplicateConfirmationPack = try await store.speakerRecognitionPack()
        XCTAssertEqual(firstConfirmationPack.revision, duplicateConfirmationPack.revision)
        let confirmedReview = try await store.fetchPersonSpeakerLinks(recordingID: reviewID)
        XCTAssertEqual(confirmedReview.first?.isUserConfirmed, true)
        _ = try await submit(reviewID)
        let afterRepeat = try await store.fetchPendingSuggestionsForRecording(reviewID)
        XCTAssertTrue(afterRepeat.isEmpty)
        // Dismiss removes only a guessed name and prevents its automatic return.
        let dismissedID = try await seedRecording(in: store, wav: "/tmp/rejected-automatic.wav")
        let automatic = try await submit(dismissedID)
        XCTAssertEqual(automatic.displayName, "Bob")
        let beforeDismissal = try await store.fetch(id: dismissedID)
        try await store.dismissSuggestion(personID: bob, recordingID: dismissedID, speakerIndex: 0)
        let dismissedLinks = try await store.fetchPersonSpeakerLinks(recordingID: dismissedID)
        XCTAssertTrue(dismissedLinks.isEmpty)
        let afterDismissal = try await store.fetch(id: dismissedID)
        XCTAssertNil(afterDismissal?.speakerNames[0])
        XCTAssertGreaterThan(try XCTUnwrap(afterDismissal?.revision), try XCTUnwrap(beforeDismissal?.revision))
        let rejectedAgain = try await submit(dismissedID)
        XCTAssertEqual(rejectedAgain.disposition, .noMatch)
        let noRestoredSuggestion = try await store.fetchPendingSuggestionsForRecording(dismissedID)
        XCTAssertTrue(noRestoredSuggestion.isEmpty)
        // The user can explicitly reverse the dismissal through the person picker.
        try await store.linkSpeaker(personID: bob, recordingID: dismissedID, speakerIndex: 0)
        let reversed = try await submit(dismissedID)
        XCTAssertEqual(reversed.displayName, "Bob")
        // A stale Dismiss must never remove a confirmed assignment or its name.
        try await store.dismissSuggestion(personID: bob, recordingID: dismissedID, speakerIndex: 0)
        let stillConfirmed = try await store.fetchPersonSpeakerLinks(recordingID: dismissedID)
        XCTAssertEqual(stillConfirmed.first?.personID, bob)
        XCTAssertEqual(stillConfirmed.first?.isUserConfirmed, true)
        let stillNamed = try await store.fetch(id: dismissedID)
        XCTAssertEqual(stillNamed?.speakerNames[0], "Bob")
        let notRejected = try await store.isDismissed(personID: bob, recordingID: dismissedID, speakerIndex: 0)
        XCTAssertFalse(notRejected)
        // A new automatic result must not overwrite a different manual assignment.
        try await store.linkSpeaker(personID: alice, recordingID: queryID, speakerIndex: 0)
        let conflict = try await submit(queryID)
        XCTAssertEqual(conflict.disposition, .pendingReview)
        let links = try await store.fetchPersonSpeakerLinks(recordingID: queryID)
        XCTAssertEqual(links.first?.personID, alice)

    }

    func test_staleConfirmationCannotOverwriteCorrectionOrRestoreUnlinkedSpeaker() async throws {
        let store = try await RecordingStore.inMemory()
        let alice = try await store.createPerson(displayName: "Alice")
        let bob = try await store.createPerson(displayName: "Bob")
        let recordingID = try await seedRecording(in: store, wav: "/tmp/stale-confirmation.wav")
        try await store.insertPendingSuggestion(personID: alice, recordingID: recordingID, speakerIndex: 0, score: 0.9)
        try await store.linkSpeaker(personID: bob, recordingID: recordingID, speakerIndex: 0)
        do {
            try await store.confirmSuggestion(personID: alice, recordingID: recordingID, speakerIndex: 0)
            XCTFail("Stale confirmation must fail")
        } catch { XCTAssertEqual(error as? StoreError, .notFound) }
        let corrected = try await store.fetchPersonSpeakerLinks(recordingID: recordingID)
        XCTAssertEqual(corrected.first?.personID, bob)
        try await store.insertPendingSuggestion(personID: alice, recordingID: recordingID, speakerIndex: 0, score: 0.9)
        try await store.unlinkSpeaker(recordingID: recordingID, speakerIndex: 0)
        let pending = try await store.fetchPendingSuggestionsForRecording(recordingID)
        XCTAssertTrue(pending.isEmpty)
        do {
            try await store.confirmSuggestion(personID: alice, recordingID: recordingID, speakerIndex: 0)
            XCTFail("Stale confirmation must not restore an unlinked speaker")
        } catch { XCTAssertEqual(error as? StoreError, .notFound) }
        let unlinked = try await store.fetchPersonSpeakerLinks(recordingID: recordingID)
        XCTAssertTrue(unlinked.isEmpty)
    }

    // MARK: - Helpers

    private func seedRecording(in store: RecordingStore, wav: String) async throws -> Int64 {
        let rec = Recording(
            wavPath: wav,
            txtPath: nil,
            jsonPath: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            transcriptText: nil
        )
        let saved = try await store.upsert(rec)
        return saved.id!
    }

    private func encodeFloat32(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}
