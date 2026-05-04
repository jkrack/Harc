import Foundation
import SwiftUI
import HarcStore

@MainActor
public final class PersonDetailViewModel: ObservableObject {
    @Published public private(set) var person: Person?
    @Published public private(set) var stats: PersonStats?
    @Published public private(set) var utterances: [UtteranceExcerpt] = []

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func load(personID: Int64) async {
        person = try? await store.fetchPeople().first(where: { $0.id == personID })
        stats = try? await store.fetchPersonStats(personID: personID)
        utterances = (try? await store.fetchUtterancesForPerson(personID: personID, limit: 20)) ?? []
    }
}
