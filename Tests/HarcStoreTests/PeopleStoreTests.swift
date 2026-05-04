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
