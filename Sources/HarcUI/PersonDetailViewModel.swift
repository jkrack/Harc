import Foundation
import SwiftUI
import HarcStore

@MainActor
public final class PersonDetailViewModel: ObservableObject {
    @Published public private(set) var person: Person?
    @Published public private(set) var stats: PersonStats?
    @Published public private(set) var utterances: [UtteranceExcerpt] = []
    @Published public private(set) var pendingSuggestions: [PendingSuggestion] = []
    @Published public private(set) var embeddings: [RecordingStore.SpeakerEmbeddingRow] = []
    @Published public private(set) var allPeopleForMerge: [Person] = []

    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func load(personID: Int64) async {
        person = try? await store.fetchPeople().first(where: { $0.id == personID })
        stats = try? await store.fetchPersonStats(personID: personID)
        utterances = (try? await store.fetchUtterancesForPerson(personID: personID, limit: 20)) ?? []
        pendingSuggestions = (try? await store.fetchPendingSuggestions(personID: personID)) ?? []
        embeddings = (try? await store.fetchEmbeddingsForPerson(personID, embedderKind: "wespeaker_v2")) ?? []
        let all = (try? await store.fetchPeople()) ?? []
        allPeopleForMerge = all.filter { $0.id != personID }
    }

    // MARK: - Suggestions

    public func confirm(_ suggestion: PendingSuggestion) async {
        try? await store.confirmSuggestion(
            personID: suggestion.personID,
            recordingID: suggestion.recordingID,
            speakerIndex: suggestion.speakerIndex
        )
        await reloadSuggestions()
    }

    public func dismiss(_ suggestion: PendingSuggestion) async {
        try? await store.dismissSuggestion(
            personID: suggestion.personID,
            recordingID: suggestion.recordingID,
            speakerIndex: suggestion.speakerIndex
        )
        await reloadSuggestions()
    }

    public func confirmAll() async {
        for s in pendingSuggestions {
            try? await store.confirmSuggestion(
                personID: s.personID,
                recordingID: s.recordingID,
                speakerIndex: s.speakerIndex
            )
        }
        await reloadSuggestions()
    }

    private func reloadSuggestions() async {
        guard let id = person?.id else { return }
        pendingSuggestions = (try? await store.fetchPendingSuggestions(personID: id)) ?? []
    }

    // MARK: - Voice prints (merge / split)

    public func split(slots: [(Int64, Int)], newName: String) async {
        _ = try? await store.splitEmbeddings(
            slots: slots.map { (recordingID: $0.0, speakerIndex: $0.1) },
            intoNewPersonNamed: newName
        )
        if let id = person?.id { await load(personID: id) }
    }

    public func merge(into targetID: Int64) async {
        guard let id = person?.id else { return }
        try? await store.mergePeople(sourceIDs: [id], into: targetID)
        // After merge this person no longer exists — caller navigates away.
    }

    // MARK: - Threshold

    public func updateThreshold(_ value: Double?) async {
        guard let id = person?.id else { return }
        try? await store.updatePersonThreshold(personID: id, threshold: value)
        if let id = person?.id { await load(personID: id) }
    }

    // MARK: - Rename / Delete

    public func rename(to newName: String) async {
        guard let id = person?.id else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? await store.renamePerson(id: id, to: trimmed)
        person?.displayName = trimmed
    }

    public func delete() async throws {
        guard let id = person?.id else { return }
        try await store.deletePerson(id: id)
    }
}
