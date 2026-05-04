import Foundation
import SwiftUI
import Combine
import GRDB
import HarcStore

@MainActor
public final class PeopleViewModel: ObservableObject {
    @Published public private(set) var people: [PersonRowItem] = []

    private let store: RecordingStore
    private var cancellable: AnyCancellable?

    public init(store: RecordingStore) {
        self.store = store
    }

    public func start() {
        guard cancellable == nil else { return }
        // Fire whenever any of the four People-related tables change.
        let observation = ValueObservation.tracking { db -> Int in
            let a = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people") ?? 0
            let b = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM person_speakers") ?? 0
            let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_suggestions") ?? 0
            let d = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dismissed_suggestions") ?? 0
            return a &+ b &+ c &+ d
        }
        cancellable = observation
            .publisher(in: store.dbReader)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] _ in
                    Task { [weak self] in
                        guard let self else { return }
                        let items = (try? await self.store.personRowItems()) ?? []
                        await MainActor.run { self.people = items }
                    }
                }
            )
        // Kick off an initial load so the sidebar isn't empty before the
        // first ValueObservation tick.
        Task { [weak self] in
            guard let self else { return }
            let items = (try? await self.store.personRowItems()) ?? []
            await MainActor.run { self.people = items }
        }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
