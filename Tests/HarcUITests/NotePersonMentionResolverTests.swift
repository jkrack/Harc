import Foundation
import Testing
import HarcStore
@testable import HarcUI

@Suite("NotePersonMentionResolver")
struct NotePersonMentionResolverTests {
    @Test("bare mention without an existing person is unresolved, not created")
    func bareMentionIsUnresolved() {
        let actions = NotePersonMentionResolver.actions(for: "Follow up with @amy", people: [])

        #expect(actions == [.unresolvedBare(name: "amy")])
    }

    @Test("bracketed mention is explicit create when no person exists")
    func bracketedMentionCreates() {
        let actions = NotePersonMentionResolver.actions(for: "Follow up with @[Amy Pond]", people: [])

        #expect(actions == [.create(name: "Amy Pond")])
    }

    @Test("bare mention links a single existing person")
    func bareMentionLinksExistingPerson() {
        let person = Person(
            id: 42,
            displayName: "Amy Pond",
            matchThreshold: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let actions = NotePersonMentionResolver.actions(for: "Follow up with @amy", people: [person])

        #expect(actions == [.link(personID: 42)])
    }

    @Test("ambiguous bare mention remains unresolved")
    func ambiguousBareMentionIsUnresolved() {
        let people = [
            Person(id: 1, displayName: "Amy Pond", matchThreshold: nil, createdAt: Date(), updatedAt: Date()),
            Person(id: 2, displayName: "Amy Santiago", matchThreshold: nil, createdAt: Date(), updatedAt: Date()),
        ]

        let actions = NotePersonMentionResolver.actions(for: "Follow up with @amy", people: people)

        #expect(actions == [.unresolvedBare(name: "amy")])
    }
}
