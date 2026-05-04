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
}
