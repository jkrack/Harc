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
}
