import Foundation
import HarcModels

@MainActor
enum ActiveSummarizerReconciler {
    static func reconcile(preferences prefs: HarcPreferences, models: ModelManagerStore) {
        guard !models.state(of: prefs.activeSummarizerID).isInstalled else { return }

        let installed = Set(
            ModelCatalog.descriptors(for: .summarizer)
                .filter { models.state(of: $0.id).isInstalled }
                .map(\.id)
        )
        let fallback = ModelCatalog.fallbackSummarizerID(
            installed: installed,
            excluding: prefs.activeSummarizerID
        )

        if fallback != prefs.activeSummarizerID {
            prefs.activeSummarizerID = fallback
        }
    }
}
