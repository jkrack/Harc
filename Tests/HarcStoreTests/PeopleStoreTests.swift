import XCTest
@testable import HarcStore

final class PeopleStoreTests: XCTestCase {

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
}
