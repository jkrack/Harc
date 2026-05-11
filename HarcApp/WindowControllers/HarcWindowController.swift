import AppKit
import SwiftUI
import HarcContext
import HarcModels
import HarcSummarize
import HarcUI
import HarcStore

@MainActor
final class HarcWindowController: NSWindowController {
    convenience init(
        libraryVM: LibraryViewModel,
        recordingState: RecordingState,
        bridge: HarcAppBridge,
        store: RecordingStore,
        reIDService: SpeakerReIDService,
        summarizerService: SummarizerService,
        knowledgeIndexer: KnowledgeIndexer?,
        prefs: HarcPreferences,
        postProcessingState: RecordingPostProcessingState,
        queueStore: SummarizationQueueStore,
        modelStore: ModelManagerStore,
        onEdit: @escaping (Recording) -> Void,
        onExport: @escaping (Recording) -> Void,
        onDelete: @escaping (Recording) -> Void
    ) {
        let peopleVM = PeopleViewModel(store: store)
        let root = HarcWindowRootView(
            libraryVM: libraryVM,
            recordingState: recordingState,
            bridge: bridge,
            peopleVM: peopleVM,
            store: store,
            reIDService: reIDService,
            summarizerService: summarizerService,
            knowledgeIndexer: knowledgeIndexer,
            onEdit: onEdit,
            onExport: onExport,
            onDelete: onDelete
        )
        .environmentObject(prefs)
        .environmentObject(postProcessingState)
        .environmentObject(queueStore)
        .environmentObject(modelStore)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.title = "Harc"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.center()
        self.init(window: window)
    }
}
