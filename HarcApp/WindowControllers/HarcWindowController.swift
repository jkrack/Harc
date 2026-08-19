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
        bridge: HarcAppBridge,
        store: RecordingStore,
        reIDService: SpeakerReIDService,
        summarizerService: SummarizerService,
        prefs: HarcPreferences,
        postProcessingState: RecordingPostProcessingState,
        queueStore: SummarizationQueueStore,
        modelStore: ModelManagerStore,
        importState: MediaImportState,
        onDelete: @escaping (Recording) -> Void,
        onImportFiles: @escaping ([URL]) -> Void,
        onCancelImport: @escaping () -> Void,
        onSummarizeSession: ((Int64) -> Void)? = nil,
        reprocessState: LocalLibraryReprocessState = LocalLibraryReprocessState(),
        onReprocessRecording: ((Recording) -> Void)? = nil,
        onReprocessAll: (() -> Void)? = nil
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
            onDelete: onDelete,
            onImportFiles: onImportFiles,
            onCancelImport: onCancelImport,
            importState: importState,
            onSummarizeSession: onSummarizeSession,
            reprocessState: reprocessState,
            onReprocessRecording: onReprocessRecording,
            onReprocessAll: onReprocessAll
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
