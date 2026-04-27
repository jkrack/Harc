import AppKit
import SwiftUI
import HarcUI
import HarcStore
import HarcModels
import HarcSummarize

@MainActor
final class TranscriptionDetailWindowController: NSWindowController {
    convenience init(
        recording: Recording,
        store: RecordingStore,
        prefs: HarcPreferences,
        queueStore: SummarizationQueueStore,
        modelStore: ModelManagerStore,
        postProcessingState: RecordingPostProcessingState,
        onReveal: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping (String?) -> Void,
        onEditTranscript: @escaping () -> Void,
        onSpeakerNamesChanged: @escaping ([Int: String]) -> Void,
        onClearSummary: @escaping (Int64) -> Void,
        suggestionsProvider: SpeakerNameEditor.SuggestionsProvider? = nil
    ) {
        let root = TranscriptionDetailView(
            recording: recording,
            store: store,
            onReveal: onReveal,
            onDelete: onDelete,
            onRename: onRename,
            onEditTranscript: onEditTranscript,
            onSpeakerNamesChanged: onSpeakerNamesChanged,
            onClearSummary: onClearSummary,
            suggestionsProvider: suggestionsProvider,
            onIdentifySpeakers: {
                // TODO Task 14: trigger diarize for recording
                print("[TranscriptionDetailWindowController] onIdentifySpeakers requested for recording id=\(recording.id?.description ?? "nil")")
            }
        )
        .environmentObject(prefs)
        .environmentObject(queueStore)
        .environmentObject(modelStore)
        .environmentObject(postProcessingState)

        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc — \(recording.displayTitle)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.center()
        self.init(window: window)
    }
}
