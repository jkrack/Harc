import AppKit
import SwiftUI
import HarcModels
import HarcSummarize
import HarcUI
import HarcStore

@MainActor
final class HarcWindowController: NSWindowController {
    convenience init(
        libraryVM: LibraryViewModel,
        recordingState: RecordingState,
        store: RecordingStore,
        reIDService: SpeakerReIDService,
        prefs: HarcPreferences,
        postProcessingState: RecordingPostProcessingState,
        queueStore: SummarizationQueueStore,
        modelStore: ModelManagerStore,
        onEdit: @escaping (Recording) -> Void,
        onExport: @escaping (Recording) -> Void,
        onDelete: @escaping (Recording) -> Void
    ) {
        let root = HarcWindowRootView(
            libraryVM: libraryVM,
            recordingState: recordingState,
            store: store,
            reIDService: reIDService,
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
