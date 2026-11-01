import AppKit
import SwiftUI
import HarcModels
import HarcSummarize
import HarcUI
import HarcStore
import HarcPresenceUI

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
        // Full-size content under a transparent title bar: the Tide gradient
        // is the window surface, so the title and toolbar sit on it instead
        // of on a wallpaper-tinted system material.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = NSColor(name: "TideWindowSurface") { appearance in
            NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? HarcTideStyle.navy : HarcTideStyle.mist)
        }
        window.setContentSize(NSSize(width: 1200, height: 720))
        window.center()
        self.init(window: window)
    }
}
