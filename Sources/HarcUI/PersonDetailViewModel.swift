import Foundation
import SwiftUI
import HarcStore

@MainActor
public final class PersonDetailViewModel: ObservableObject {
    @Published public private(set) var person: Person?
    @Published public private(set) var stats: PersonStats?
    @Published public private(set) var utterances: [UtteranceExcerpt] = []
    @Published public private(set) var pendingSuggestions: [PendingSuggestion] = []
    @Published public private(set) var enrolledEvidence: [RecordingStore.EnrolledSpeakerEvidence] = []
    @Published public private(set) var embeddings: [RecordingStore.SpeakerEmbeddingRow] = []
    @Published public private(set) var allPeopleForMerge: [Person] = []

    @Published var mutationFailure: LibraryMutationFailure?

    private var suggestionReviews = SpeakerSuggestionReviewBatch.empty
    private var suggestionLoadID = UUID()
    private let store: RecordingStore

    public init(store: RecordingStore) {
        self.store = store
    }

    public func load(personID: Int64) async {
        person = try? await store.fetchPeople().first(where: { $0.id == personID })
        stats = try? await store.fetchPersonStats(personID: personID)
        utterances = (try? await store.fetchUtterancesForPerson(personID: personID, limit: 20)) ?? []
        await reloadSuggestions(personID: personID)
        embeddings = (try? await store.fetchEmbeddingsForPerson(personID, embedderKind: "wespeaker_v2")) ?? []
        do { enrolledEvidence = try await store.enrolledSpeakerEvidence(personID: personID) }
        catch {
            enrolledEvidence = []
            mutationFailure = LibraryMutationFailure(action: .loadSpeakerEvidence, error: error)
        }
        let all = (try? await store.fetchPeople()) ?? []
        allPeopleForMerge = all.filter { $0.id != personID }
    }

    // MARK: - Suggestions

    public func confirm(_ suggestion: PendingSuggestion) async {
        mutationFailure = nil
        do {
            try await suggestionReviews.confirm(suggestion, store: store)
        } catch {
            mutationFailure = LibraryMutationFailure(action: .confirmSpeakerSuggestion, error: error)
        }
        await reloadSuggestions()
    }

    public func dismiss(_ suggestion: PendingSuggestion) async {
        mutationFailure = nil
        do {
            try await store.dismissSuggestion(personID: suggestion.personID,
                recordingID: suggestion.recordingID, speakerIndex: suggestion.speakerIndex)
        } catch {
            mutationFailure = LibraryMutationFailure(action: .dismissSpeakerSuggestion, error: error)
        }
        await reloadSuggestions()
    }

    public func confirmAll() async {
        mutationFailure = nil
        for suggestion in pendingSuggestions {
            do {
                try await suggestionReviews.confirm(suggestion, store: store)
            } catch {
                // Earlier confirmations remain committed. Stop here and refresh
                // so the user can review the remaining work after the failure.
                mutationFailure = LibraryMutationFailure(action: .confirmSpeakerSuggestion, error: error)
                break
            }
        }
        await reloadSuggestions()
    }

    private func reloadSuggestions(personID: Int64? = nil) async {
        guard let id = personID ?? person?.id else { return }
        let loadID = UUID()
        suggestionLoadID = loadID
        let suggestions = (try? await store.fetchPendingSuggestions(personID: id)) ?? []
        let reviews = await SpeakerSuggestionReviewBatch.load(suggestions, store: store)
        guard suggestionLoadID == loadID else { return }
        suggestionReviews = reviews
        pendingSuggestions = suggestions
    }

    public func splitEvidence(ids: Set<Data>, newName: String) async {
        mutationFailure = nil
        guard let personID = person?.id else { return }
        do {
            let selected = enrolledEvidence.filter { ids.contains($0.id) }
            guard selected.count == ids.count else { throw StoreError.invalidData("The selected voice samples changed") }
            _ = try await store.splitSpeakerEvidence(selected, personID: personID, newName: newName)
        } catch {
            mutationFailure = LibraryMutationFailure(action: .splitSpeakerEvidence, error: error)
        }
        await load(personID: personID)
    }

    // MARK: - Voice prints (merge / split)

    @discardableResult
    public func split(slots: [(Int64, Int)], newName: String) async -> Bool {
        mutationFailure = nil
        do {
            guard !slots.isEmpty else { throw StoreError.invalidData("Select voice samples to split") }
            _ = try await store.splitEmbeddings(
                slots: slots.map { (recordingID: $0.0, speakerIndex: $0.1) },
                intoNewPersonNamed: newName
            )
            if let id = person?.id { await load(personID: id) }
            return true
        } catch {
            mutationFailure = LibraryMutationFailure(action: .splitSpeakerEvidence, error: error)
            return false
        }
    }

    @discardableResult
    public func merge(into targetID: Int64) async -> Bool {
        mutationFailure = nil
        guard let id = person?.id else { return false }
        do {
            try await store.mergePeople(sourceIDs: [id], into: targetID)
            return true
        } catch {
            mutationFailure = LibraryMutationFailure(action: .mergePeople, error: error)
            return false
        }
    }

    // MARK: - Threshold

    public func updateThreshold(_ value: Double?) async {
        mutationFailure = nil
        guard let id = person?.id else { return }
        do {
            try await store.updatePersonThreshold(personID: id, threshold: value)
            if person?.id == id { person?.matchThreshold = value }
        } catch {
            mutationFailure = LibraryMutationFailure(action: .updateSpeakerThreshold, error: error)
        }
    }

    // MARK: - Rename / Delete

    public func rename(to newName: String) async {
        mutationFailure = nil
        guard let id = person?.id else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await store.renamePerson(id: id, to: trimmed)
            if person?.id == id { person?.displayName = trimmed }
        } catch {
            mutationFailure = LibraryMutationFailure(action: .renameSpeaker, error: error)
        }
    }

    public func deleteWithFeedback() async -> Bool {
        mutationFailure = nil
        guard person?.id != nil else { return false }
        do {
            try await delete()
            return true
        } catch {
            mutationFailure = LibraryMutationFailure(action: .deletePerson, error: error)
            return false
        }
    }

    public func delete() async throws {
        guard let id = person?.id else { return }
        try await store.deletePerson(id: id)
    }
}
