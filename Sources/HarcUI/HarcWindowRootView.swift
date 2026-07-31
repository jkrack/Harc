import SwiftUI
import Foundation
import KeyboardShortcuts
import HarcStore
import HarcExport
import HarcClient
import HarcCore
import HarcModels
import HarcSummarize
import HarcAudio
import AppKit
import UniformTypeIdentifiers

// MARK: - Notifications

public extension NSNotification.Name {
    /// Posted by AppDelegate when the user invokes "open library + focus search".
    /// `HarcWindowRootView` observes this to activate its search field.
    static let harcLibraryFocusSearch = NSNotification.Name("HarcLibraryFocusSearch")
}


// MARK: - HarcWindowRootView

/// Main window root view. Hosts a `NavigationSplitView` with a recording-list
/// sidebar (grouped by date / pinned), a transcript detail pane, and an
/// inspector panel showing speaker and file metadata.
///
/// Toolbar actions (Edit, Export, Delete, recording pill) are wired in.
/// This view is hosted by `HarcWindowController`.
public struct HarcWindowRootView: View {
    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var bridge: HarcAppBridge
    @ObservedObject var peopleVM: PeopleViewModel

    let store: RecordingStore
    let reIDService: SpeakerReIDService
    let summarizerService: SummarizerService
    let onDelete: (Recording) -> Void
    /// Import audio/video files into the library. Nil hides the import
    /// button and disables drag-and-drop (e.g. in previews/tests).
    let onImportFiles: (([URL]) -> Void)?
    /// Cancel the in-flight import batch. Nil hides the banner's Cancel.
    let onCancelImport: (() -> Void)?
    @ObservedObject var importState: MediaImportState

    // MARK: View state

    /// Primary selection — `.recording(wavPath:)` for recordings, `.person(id:)` for People.
    @State var selection: LibrarySelection?
    @State var mutationFailure: LibraryMutationFailure?
    @State var inspectorOpen: Bool = false
    @State var showingAddPerson = false

    // Transcript text is loaded lazily on selection change to avoid
    // synchronous disk I/O in the view body.
    @State var transcriptText: String = ""
    /// Set when the user picks Delete from a sidebar context menu — drives
    /// the destructive confirmation alert.
    @State var pendingDeleteRecording: Recording? = nil
    /// When the .json sidecar is available, we render structured turns
    /// (timestamp + speaker + text) instead of the flat .txt blob.
    @State var transcriptSegments: [TranscriptDisplaySegment] = []
    @State var transcriptLoadError: String? = nil
    @State var transcriptFindVisible = false
    @State var transcriptSearchText = ""
    @State var transcriptSearchIndex = 0
    @FocusState var transcriptSearchFocused: Bool
    @State var detailEnvelope: [Float] = []
    /// Loader/saver for the recording open in the detail pane — the OKF-aware
    /// engine the retired editor window used, now serving the single surface.
    @State var detailDocument: TranscriptDocument? = nil
    /// The editable transcript the pane binds to. Autosaved on pause.
    @State var editorText: String = ""
    @State var editorHighlight: NSRange? = nil
    @State var editorDirty = false
    @State var editorSaveError: String? = nil
    @State var lastAutosaveAt: Date? = nil
    @State var autosaveTask: Task<Void, Never>? = nil
    /// Character offsets where a speaker turn begins ("Name: …" lines),
    /// computed at load for the boundary-jump commands.
    @State var speakerBoundaries: [Int] = []
    @State var titleDraft: String = ""
    /// The one playback transport for the pane — the transcript's
    /// ⌘-click-to-seek and word highlight drive the same clock the waveform
    /// shows, instead of the second player the editor window used to own.
    @StateObject var playerModel = WaveformPlayerModel()
    /// The Activity sheet — readiness, recovery and running jobs, told once.
    @State var showActivity = false
    /// Resolved speaker labels for the current selection, keyed by speaker
    /// index. Populated asynchronously on selection change via
    /// `loadResolvedLabels()` so Person-linked names show up in transcript
    /// turns. Falls back to the raw `recordings.speaker_names` JSON or
    /// "Speaker N+1" when no Person link exists (same resolution order as
    /// `RecordingStore.resolvedSpeakerName`).
    @State var resolvedSpeakerLabels: [Int: String] = [:]

    // Task 8.1: pending suggestions for the inspector chip system
    @State var inspectorPendingSuggestions: [PendingSuggestion] = []
    // Task 8.1/8.2: Person name lookup and full list for the picker
    @State var allPeopleByID: [Int64: String] = [:]
    @State var allPeople: [Person] = []
    @State var restoredSelection: LibrarySelection?
    @State var exportRecording: Recording?
    @State var exportDraft = RecordingExportDraft(includeSummary: true)
    /// True while a drag with file URLs hovers over the window.
    @State var importDropTargeted = false

    // MARK: Environment

    @EnvironmentObject var prefs: HarcPreferences
    @EnvironmentObject var postProcessing: RecordingPostProcessingState
    @EnvironmentObject var modelStore: ModelManagerStore

    // MARK: Init

    public init(
        libraryVM: LibraryViewModel,
        recordingState: RecordingState,
        bridge: HarcAppBridge,
        peopleVM: PeopleViewModel,
        store: RecordingStore,
        reIDService: SpeakerReIDService,
        summarizerService: SummarizerService,
        onDelete: @escaping (Recording) -> Void,
        onImportFiles: (([URL]) -> Void)? = nil,
        onCancelImport: (() -> Void)? = nil,
        importState: MediaImportState = MediaImportState()
    ) {
        self.libraryVM = libraryVM
        self.recordingState = recordingState
        self.bridge = bridge
        self.peopleVM = peopleVM
        self.store = store
        self.reIDService = reIDService
        self.summarizerService = summarizerService
        self.onDelete = onDelete
        self.onImportFiles = onImportFiles
        self.onCancelImport = onCancelImport
        self.importState = importState
    }

    // MARK: Body

    var pendingDeleteRecordingBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteRecording != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteRecording = nil }
            }
        )
    }

    var recordingPathsForNavigation: [String] {
        libraryVM.recordings.map(\.wavPath)
    }

    var personIDsForNavigation: [Int64] {
        peopleVM.people.map { $0.person.id }
    }

    var navigationValidationToken: String {
        [
            recordingPathsForNavigation.joined(separator: "\u{1f}"),
            personIDsForNavigation.map(String.init).joined(separator: "\u{1f}"),
        ].joined(separator: "\u{1e}")
    }

    public var body: some View {
        return VStack(spacing: 0) {
            split
            Divider()
            libraryFooter
        }
        .frame(minWidth: 900, minHeight: 600)
        .accessibilityIdentifier("harc.library.root")
        .onDrop(of: [.fileURL], isTargeted: $importDropTargeted) { providers in
            handleImportDrop(providers)
        }
        .overlay {
            // Drop-highlight while a file drag hovers — import affordance.
            if importDropTargeted, onImportFiles != nil {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showActivity) {
            ActivityView(
                bridge: bridge,
                importState: importState,
                onDismiss: { showActivity = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .harcLibraryShowActivity)) { _ in
            showActivity = true
        }
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: selection) { old, _ in
            flushPendingDetailEdits(previousSelection: old)
            persistNavigationSnapshot()
            loadTranscript()
            Task { await loadEnvelope() }
            Task { await loadResolvedLabels() }
        }
        .onChange(of: navigationValidationToken) { _, _ in restoreOrValidateSelection() }
        .alert(
            "Delete recording?",
            isPresented: pendingDeleteRecordingBinding,
            presenting: pendingDeleteRecording
        ) { rec in
            Button("Delete", role: .destructive) {
                let target = rec
                pendingDeleteRecording = nil
                Task {
                    do {
                        try await libraryVM.delete(recording: target)
                        if selection == .recording(wavPath: target.wavPath) { selection = nil }
                        mutationFailure = nil
                    } catch {
                        reportMutationFailure(.deleteRecording(target.displayTitle), error: error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeleteRecording = nil }
        } message: { rec in
            Text("\u{201C}\(rec.displayTitle)\u{201D} will be removed from the library and the audio + transcript files will be deleted from disk.")
        }
        .sheet(isPresented: $showingAddPerson) {
            AddPersonSheet { name in
                Task {
                    do {
                        _ = try await store.createPerson(displayName: name)
                        showingAddPerson = false
                        mutationFailure = nil
                    } catch {
                        reportMutationFailure(.addPerson(name), error: error)
                    }
                }
            }
        }
        .sheet(item: $exportRecording) { recording in
            RecordingExportSheet(
                recording: recording,
                draft: $exportDraft,
                onCancel: { exportRecording = nil },
                onExported: { exportRecording = nil }
            )
        }
    }

    func handleAppear() {
        restoreNavigationSnapshot()
        libraryVM.start()
        peopleVM.start()
    }

    func handleDisappear() {
        libraryVM.stop()
        peopleVM.stop()
    }

    @ViewBuilder
    var split: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $libraryVM.searchText,
            placement: .sidebar,
            prompt: "Search titles and transcripts"
        )
        .toolbar {
            // Leading: the app's primary action, present in every state.
            // Idle it is a prominent Record button; recording it becomes the
            // live pill — the same control, so starting and stopping live in
            // one place and the accessibility identifier never moves. This
            // replaced a Record button buried ~310pt down the sidebar, below
            // the calendar, where short windows put it under the fold.
            ToolbarItem(placement: .navigation) {
                recordToolbarControl
            }

            // Trailing group, cut to the three things people actually do
            // here. Six undifferentiated icon buttons put Delete beside
            // Export; Delete now lives in the row context menu and on the
            // delete key, and Import lives in File › Import and the empty
            // state, where a rare action belongs.
            ToolbarItemGroup {
                Button {
                    if let rec = currentRecording { copyForPrompt(rec) }
                } label: {
                    // The actual job, labeled: this is what feeds an LLM.
                    Label("Copy for Prompt", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(currentRecording == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the prompt-formatted transcript for pasting into an LLM")

                Menu {
                    Button("Copy Transcript Only") {
                        if let rec = currentRecording { copyTranscript(rec) }
                    }
                    Divider()
                    Button("Export…") {
                        if let rec = currentRecording { presentExport(rec) }
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(currentRecording == nil)

                Button {
                    inspectorOpen.toggle()
                } label: {
                    Label(inspectorToolbarTitle, systemImage: "sidebar.right")
                }
                .help("Toggle inspector panel")
            }
        }
    }

    var inspectorToolbarTitle: String {
        let count = inspectorAttentionCount
        return count > 0 ? "Inspector (\(count))" : "Inspector"
    }

    var inspectorAttentionCount: Int {
        inspectorPendingSuggestions.count
    }

    // MARK: - Library footer (status bar)

    var libraryFooter: some View {
        HStack(spacing: 0) {
            Text(footerCountAndStorage)
                .font(.harcMono)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 16)
            footerStatus
        }
        .padding(.horizontal, HarcSpacing.lg)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Media import

    /// Compact status bar above the footer while an import runs (or just
    /// finished / failed). Hidden entirely when there is nothing to show.

    /// NSOpenPanel for File-style import. Multi-select; filtered to the
    /// audio/video types MediaImportService can convert.
    func presentImportPanel() {
        guard let onImportFiles else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Audio or Video"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaImportService.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls.filter(MediaImportService.isSupported)
            if !urls.isEmpty { onImportFiles(urls) }
        }
    }

    /// Drag-and-drop entry: collect file URLs off the providers, filter to
    /// supported media types, and hand them to the import pipeline.
    func handleImportDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let onImportFiles else { return false }
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty else { return false }

        let collector = DropURLCollector(expected: candidates.count) { urls in
            let supported = urls.filter(MediaImportService.isSupported)
            if !supported.isEmpty { onImportFiles(supported) }
        }
        for provider in candidates {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                collector.add(url)
            }
        }
        return true
    }

    /// The right side of the footer is the live status line — what is
    /// running right now — plus the LOCAL badge, which is the product's
    /// whole claim and earns permanence. The hardware and model string that
    /// used to sit here never changed for the lifetime of an install; it
    /// lives in Settings › About now. Tapping the status opens Activity.
    var footerStatus: some View {
        HStack(spacing: HarcSpacing.sm) {
            if let live = footerLiveStatusText {
                Button {
                    showActivity = true
                } label: {
                    HStack(spacing: HarcSpacing.sm) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(live)
                            .font(.harcCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Open Activity")
                Text("·").foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            }
            Text("LOCAL")
                .font(.harcMono.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(Color.harc(.ready))
                .help("All transcription and summarization runs on this Mac")
        }
    }

    var footerLiveStatusText: String? {
        if let job = importState.current {
            let queued = importState.queuedCount > 0 ? " (+\(importState.queuedCount))" : ""
            return "\(job.phaseText.isEmpty ? "Importing" : job.phaseText) \(job.filename)\(queued)"
        }
        if case .identifying = postProcessing.current?.phase {
            return "Identifying speakers…"
        }
        return nil
    }

    var footerCountAndStorage: String {
        let isSearching = !libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let count = isSearching ? libraryVM.hits.count : libraryVM.recordings.count
        let label = count == 1 ? "recording" : "recordings"
        return "\(count) \(label) · \(footerStorageString)"
    }

    var footerStorageString: String {
        let fmt = ByteCountFormatter()
        // KB included deliberately. Restricting to MB/GB rendered any library
        // under half a megabyte as "0 MB", which reads as a library that
        // failed to load rather than one that is simply small.
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: libraryVM.totalBytes)
    }

    // MARK: - Sidebar

    @ViewBuilder
    var sidebar: some View {
        VStack(spacing: 0) {
            dateScopeBar
            Group {
                if libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    groupedList
                } else {
                    searchResultsList
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Library")
        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 480)
        // Attached to the sidebar container, NOT to groupedList: the grouped
        // list leaves the hierarchy while a search is active, and a modifier
        // on a removed view never fires. Stopping a recording mid-search
        // used to strand `selection == .live` on the "Recording Finished"
        // placeholder, and the eventual DB-observation fallback landed on
        // the pinned-first head of the list instead of the new recording.
        .onChange(of: recordingState.isRecording) { _, isRecording in
            if isRecording {
                // Starting a capture is the strongest possible statement of
                // intent — show it.
                selection = .live
            } else if selection == .live {
                // Hand off to the finished file once it exists; the library
                // observer will deliver the row moments after stop.
                if let finished = recordingState.lastResult?.wavURL.path {
                    selection = .recording(wavPath: finished)
                } else {
                    selection = nil
                }
            }
        }
        // Delete left the toolbar (it sat beside Export, icon-only); the
        // keyboard path is the delete key, routed through the same
        // confirmation alert as the context menu.
        .onDeleteCommand {
            if let rec = currentRecording { pendingDeleteRecording = rec }
        }
    }

    // MARK: - Date scope

    /// The month grid used to sit permanently expanded at the top of the
    /// sidebar — 200pt of its best space spent on a rare filter, with a
    /// filled accent "selected day" competing against the filled accent
    /// selected row a few pixels below it. It is now a scope control: one
    /// compact line under the search field, and the grid (day-dots and all)
    /// lives in a popover that exists only while it is being used.
    @State private var dateScopePopoverOpen = false

    var dateScopeBar: some View {
        HStack(spacing: HarcSpacing.sm) {
            Button {
                // Surface the month that actually has recordings the moment
                // the grid appears, not whatever month it last showed.
                libraryVM.alignCalendarForPresentation()
                dateScopePopoverOpen = true
            } label: {
                HStack(spacing: HarcSpacing.xs) {
                    Image(systemName: "calendar")
                    Text(selectedFilterDay.map(formatFilterDay) ?? "All dates")
                        .font(.harcCaption)
                    Image(systemName: "chevron.down")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedFilterDay == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            .popover(isPresented: $dateScopePopoverOpen, arrowEdge: .bottom) {
                MonthCalendarView(
                    month: libraryVM.calendarMonth,
                    selectedDay: selectedFilterDay,
                    daysWithRecordings: libraryVM.daysWithRecordings,
                    onPrevMonth: { libraryVM.advanceMonth(by: -1) },
                    onNextMonth: { libraryVM.advanceMonth(by: 1) },
                    onSelectDay: { day in
                        // Toggle: picking the already-selected day clears.
                        if let current = selectedFilterDay,
                           Calendar.current.isDate(current, inSameDayAs: day) {
                            libraryVM.filter = .all
                        } else {
                            libraryVM.filter = .day(day)
                        }
                        dateScopePopoverOpen = false
                    }
                )
                .padding(HarcSpacing.md)
                .frame(width: 260)
            }

            if selectedFilterDay != nil {
                Button {
                    libraryVM.filter = .all
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show all dates")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, HarcSpacing.md)
        .padding(.vertical, HarcSpacing.sm)
    }

    var selectedFilterDay: Date? {
        if case .day(let d) = libraryVM.filter { return d }
        return nil
    }

    func formatFilterDay(_ day: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: day)
    }

    // Grouped library list: capture work stays first; organization surfaces
    // remain available without competing with the common record-review loop.
    var groupedList: some View {
        List(selection: $selection) {
            // The in-progress recording is the most interesting thing the
            // app can show, so it is the first row whenever it exists —
            // selectable like any other, not a mode you reach by deselecting.
            if recordingState.isRecording {
                Section {
                    liveRecordingRow
                }
            }

            recordingsSections

            Section {
                peopleSidebarList
            } header: {
                Label("People", systemImage: "person.2")
            }
        }
    }

    /// The saturated row is reserved for this — the one place urgency is
    /// real. Everything else uses the system's quiet selection.
    var liveRecordingRow: some View {
        HStack(spacing: HarcSpacing.sm) {
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording")
                    .font(.harcBody.weight(.semibold))
                    .foregroundStyle(.white)
                if let start = recordingState.recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ElapsedFormatter.string(since: start, now: context.date))
                            .font(.harcCaption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            Spacer(minLength: 4)
            LiveWaveformView(
                history: bridge.amplitudeHistory,
                size: .pill,
                isActive: true,
                tint: .white
            )
            .frame(width: 44, height: 14)
        }
        .padding(.vertical, HarcSpacing.sm)
        .padding(.horizontal, HarcSpacing.sm)
        .background(HarcBrand.live, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .tag(LibrarySelection.live)
        .accessibilityIdentifier("harc.library.liveRow")
        .accessibilityLabel("Recording in progress")
    }


    /// The single Record control in the toolbar's leading slot.
    ///
    /// One button, three faces: Record when idle, the live pill (dot +
    /// waveform + elapsed) while recording — tap to stop — and an hourglass
    /// while a stop is finalizing. The `harc.library.capture.recordButton`
    /// identifier stays on the control across all three, which is what keeps
    /// the record→stop UI test's three clicks landing on one element.
    var recordToolbarControl: some View {
        Button {
            bridge.onStartStop()
        } label: {
            if recordingState.isRecording {
                HStack(spacing: HarcSpacing.sm) {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                    LiveWaveformView(
                        history: bridge.amplitudeHistory,
                        size: .pill,
                        isActive: true,
                        tint: WavePalette.center
                    )
                    .frame(width: 60, height: 16)
                    if let start = recordingState.recordingStartedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(ElapsedFormatter.string(since: start, now: context.date))
                                .font(.harcLabel.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    } else {
                        Text("Recording")
                            .font(.harcLabel)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, HarcSpacing.md)
                .padding(.vertical, HarcSpacing.xs)
                .glassEffect(.regular.tint(HarcBrand.live), in: Capsule())
                .overlay(Capsule().stroke(HarcBrand.live.opacity(0.4), lineWidth: 1))
            } else if isRecordingActionBusy {
                Label(recordingActionTitle, systemImage: "hourglass")
            } else {
                Label("Record", systemImage: "record.circle")
                    .foregroundStyle(HarcBrand.live)
                    .fontWeight(.semibold)
                    .labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRecordingActionBusy)
        .help(recordToolbarHelp)
        .accessibilityIdentifier("harc.library.capture.recordButton")
        .accessibilityLabel(recordingState.isRecording ? "Stop recording" : "Start recording")
    }

    var recordToolbarHelp: String {
        if recordingState.isRecording { return "Stop recording" }
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return "Start recording (\(shortcut))"
        }
        return "Start recording"
    }

    var isRecordingActionBusy: Bool {
        bridge.recordingStopInFlight || isIdentifyingStoppedRecording
    }

    var isIdentifyingStoppedRecording: Bool {
        if case .identifying = postProcessing.current?.phase { return true }
        return false
    }

    var recordingActionTitle: String {
        if bridge.recordingStopInFlight { return "Stopping..." }
        if isIdentifyingStoppedRecording { return "Processing..." }
        return recordingState.isRecording ? "Stop" : "Record"
    }



    /// Sections, not disclosure groups. Recordings render as one flat
    /// day-grouped run of top-level sections — sticky headers, no nesting to
    /// open before the content is visible — and People is a peer root, not a
    /// second drawer. The old expansion state stays persisted but unused
    /// until the reorder mechanism is retired with it.

    @ViewBuilder
    var recordingsSections: some View {
        if libraryVM.recordings.isEmpty {
            Section {
                recordingsEmptyState
            } header: {
                Label("Recordings", systemImage: "waveform")
            }
        } else {
            let pinned = libraryVM.recordings.filter(\.pinned)
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { rec in
                        recordingLabel(rec)
                    }
                } header: {
                    Text("Pinned")
                }
            }

            let unpinned = libraryVM.recordings.filter { !$0.pinned }
            ForEach(Self.dateBuckets(from: unpinned), id: \.label) { bucket in
                Section {
                    ForEach(bucket.recordings) { rec in
                        recordingLabel(rec)
                    }
                } header: {
                    Text(bucket.label)
                }
            }
        }
    }





    /// Names the actual hotkey when one is bound — the empty state is where
    /// a new user learns the keyboard path, now that the sidebar no longer
    /// carries permanent onboarding copy.
    var emptyStateSubtitle: String {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return "Start a capture with the Record button, \(shortcut), or the menu bar icon."
        }
        return "Start a capture with the Record button or the menu bar icon."
    }

    var recordingsEmptyState: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.md) {
            EmptyStateView(
                icon: "waveform.slash",
                title: "No recordings yet",
                subtitle: emptyStateSubtitle
            )
            HStack(spacing: HarcSpacing.sm) {
                Button("Record") { bridge.onStartStop() }
                    .buttonStyle(.borderedProminent)
                if onImportFiles != nil {
                    Button("Import…") { presentImportPanel() }
                        .buttonStyle(.bordered)
                }
                Button("Settings") { openSettings() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    var peopleSidebarList: some View {
        ForEach(peopleVM.people) { item in
            HStack(spacing: HarcSpacing.sm) {
                PersonAvatar(displayName: item.person.displayName, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.person.displayName)
                        .font(.harcBody)
                        .lineLimit(1)
                    if let lastSeen = item.lastSeen {
                        Text(Self.relativeDate(lastSeen))
                            .font(.harcCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if item.suggestionCount > 0 {
                    Text("\(item.suggestionCount)")
                        .font(.harcCaption.weight(.semibold))
                        .padding(.horizontal, HarcSpacing.sm)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.harc(.attention).opacity(0.25)))
                        .foregroundStyle(.primary)
                }
            }
            .tag(LibrarySelection.person(id: item.person.id))
        }
        Button {
            showingAddPerson = true
        } label: {
            Label("Add person\u{2026}", systemImage: "person.crop.circle.badge.plus")
                .font(.harcLabel)
        }
        .buttonStyle(.plain)
    }




    func restoreNavigationSnapshot() {
        let snapshot = LibraryNavigationStateStore.load()
        restoredSelection = snapshot.selection?.librarySelection
        if let restoredSelection {
            selection = restoredSelection
        }
    }

    func persistNavigationSnapshot() {
        LibraryNavigationStateStore.save(LibraryNavigationSnapshot(
            // flatMap: the persisted form is failable — `.live` encodes as
            // no selection at all.
            selection: selection.flatMap(PersistedLibrarySelection.init)
        ))
    }

    func restoreOrValidateSelection() {
        // A live selection is owned by the recording lifecycle, not by list
        // contents — imports or deletes mid-recording must not yank the user
        // off the in-progress view. The stop handoff re-routes it.
        if selection == .live, recordingState.isRecording { return }
        let candidate = restoredSelection ?? selection
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: candidate,
            recordingPaths: Set(libraryVM.recordings.map(\.wavPath)),
            personIDs: Set(peopleVM.people.map { $0.person.id }),
            fallbackRecordingPath: libraryVM.recordings.first?.wavPath
        )
        restoredSelection = nil
        if selection != resolved {
            selection = resolved
        } else {
            persistNavigationSnapshot()
        }
    }

    // Search-results list: uses TranscriptHitRow for snippet highlighting.
    @ViewBuilder
    var searchResultsList: some View {
        if let searchError = libraryVM.searchError {
            List {
                EmptyStateView(
                    icon: "exclamationmark.magnifyingglass",
                    title: "Search index unavailable",
                    subtitle: searchError
                )
            }
        } else if libraryVM.hits.isEmpty {
            List {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    subtitle: "No titles or transcripts matched \u{201C}\(libraryVM.searchText)\u{201D}."
                )
            }
        } else {
            List(selection: $selection) {
                Section("Recordings") {
                    ForEach(libraryVM.hits) { hit in
                        TranscriptHitRow(hit: hit, onEdit: {
                            // "Edit" from search means: open it — the pane
                            // edits in place.
                            selection = .recording(wavPath: hit.recording.wavPath)
                        })
                        .tag(LibrarySelection.recording(wavPath: hit.recording.wavPath))
                        .contextMenu { contextMenu(for: hit.recording) }
                    }
                }
            }
        }
    }

    /// Recording row for use inside a `List(selection:)`. The tag is `wavPath`
    /// to match `selection`.
    func recordingLabel(_ rec: Recording) -> some View {
        let isSelected = selection == .recording(wavPath: rec.wavPath)
        return HStack(alignment: .top, spacing: HarcSpacing.sm) {
            Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                .foregroundStyle(Color.accentColor) // pinned is decoration, not status — the glyph shape carries it
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.displayTitle)
                    .font(isSelected ? .body.weight(.semibold) : .body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                // The timestamp is context now, not identity — it shares the
                // secondary line with duration and speaker count.
                Text(Self.rowSecondaryLine(for: rec))
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // One line of what was actually said, so a row is scannable
                // without opening it. Only when the title is a real title —
                // under a bare timestamp a snippet just adds noise to noise.
                if rec.title?.isEmpty == false || rec.suggestedTitle?.isEmpty == false,
                   !rec.preview.isEmpty {
                    Text(rec.preview)
                        .font(.harcCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, HarcSpacing.xs)
        .frame(minHeight: 44, alignment: .topLeading)
        // Quiet selection. The system's emphasized accent fill made the
        // selected row the loudest element in a window whose real content is
        // a paragraph of text — the eye landed in the sidebar and had to be
        // dragged out. A low-opacity wash plus the semibold title above is
        // the treatment Finder-class sidebars use; the saturated fill is
        // reserved for the live recording row, where urgency is real.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
                .padding(.horizontal, HarcSpacing.xs)
        )
        .tag(LibrarySelection.recording(wavPath: rec.wavPath))
        .accessibilityIdentifier("harc.library.recording.\(rec.id.map(String.init) ?? rec.wavPath)")
        .contentShape(Rectangle())
        .onTapGesture {
            selection = .recording(wavPath: rec.wavPath)
        }
        // Double-click used to open the second window; the detail pane IS
        // the editor now, so a second click has nothing extra to add.
        .contextMenu { contextMenu(for: rec) }
    }

    @ViewBuilder
    func contextMenu(for rec: Recording) -> some View {
        Button("Copy transcript") { copyTranscript(rec) }
        Divider()
        Button(rec.pinned ? "Unpin" : "Pin") {
            guard let id = rec.id else { return }
            Task {
                do {
                    try await libraryVM.togglePin(id: id, currentlyPinned: rec.pinned)
                    mutationFailure = nil
                } catch {
                    reportMutationFailure(.pinRecording(rec.displayTitle), error: error)
                }
            }
        }
        Button("Export…") { presentExport(rec) }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
        }
        Button("Delete", role: .destructive) {
            pendingDeleteRecording = rec
        }
    }

    func presentExport(_ recording: Recording) {
        exportDraft = RecordingExportDraft(includeSummary: prefs.includeSummaryInPrompt)
        exportRecording = recording
    }

    // MARK: - Inspector

    func inspectorContent(recording: Recording) -> some View {
        Form {
            SpeakerInspectorSection(
                speakerIndices: speakerIndices(for: recording),
                // Use resolvedSpeakerLabels so Person-linked display names
                // appear in the inspector menu labels. Falls back to
                // recording.speakerNames (via the resolver) for recordings
                // without People links.
                initialNames: resolvedSpeakerLabels.isEmpty ? recording.speakerNames : resolvedSpeakerLabels,
                onCommit: { newNames in
                    guard let id = recording.id else { return }
                    Task {
                        do {
                            try await store.updateSpeakerNames(id: id, names: newNames)
                            await loadResolvedLabels()
                            mutationFailure = nil
                        } catch {
                            reportMutationFailure(.renameSpeaker, error: error)
                        }
                    }
                },
                suggestionsProvider: nil,
                pendingSuggestions: inspectorPendingSuggestions,
                personNamesByID: allPeopleByID,
                onConfirmSuggestion: { s in
                    Task {
                        do {
                            try await store.confirmSuggestion(
                                personID: s.personID,
                                recordingID: s.recordingID,
                                speakerIndex: s.speakerIndex
                            )
                            await loadInspectorSummaryData(for: recording)
                            await loadResolvedLabels()
                            mutationFailure = nil
                        } catch {
                            reportMutationFailure(.confirmSpeakerSuggestion, error: error)
                        }
                    }
                },
                onDismissSuggestion: { s in
                    Task {
                        do {
                            try await store.dismissSuggestion(
                                personID: s.personID,
                                recordingID: s.recordingID,
                                speakerIndex: s.speakerIndex
                            )
                            await loadInspectorSummaryData(for: recording)
                            mutationFailure = nil
                        } catch {
                            reportMutationFailure(.dismissSpeakerSuggestion, error: error)
                        }
                    }
                },
                recordingID: recording.id,
                allPeople: allPeople,
                onLinkPerson: { personID, speakerIndex in
                    guard let rid = recording.id else { return }
                    Task {
                        do {
                            try await store.linkSpeaker(personID: personID, recordingID: rid, speakerIndex: speakerIndex)
                            await loadInspectorSummaryData(for: recording)
                            await loadResolvedLabels()
                            mutationFailure = nil
                        } catch {
                            reportMutationFailure(.linkSpeaker, error: error)
                        }
                    }
                },
                onCreatePerson: { name, speakerIndex in
                    guard let rid = recording.id else { return }
                    Task {
                        do {
                            let pid = try await store.createPerson(displayName: name, matchThreshold: nil)
                            try await store.linkSpeaker(personID: pid, recordingID: rid, speakerIndex: speakerIndex)
                            // Best-effort, non-blocking: backfill suggestions for the new person.
                            Task.detached { [store] in
                                let engine = SpeakerSuggestionEngine(store: store, embedderKind: "wespeaker_v2")
                                try? await engine.suggestForNewPerson(personID: pid, fromRecording: rid, speakerIndex: speakerIndex)
                            }
                            await loadInspectorSummaryData(for: recording)
                            await loadResolvedLabels()
                            mutationFailure = nil
                        } catch {
                            reportMutationFailure(.createAndLinkPerson(name), error: error)
                        }
                    }
                },
                onUnlinkPerson: { speakerIndex in
                    guard let rid = recording.id else { return }
                    Task {
                        do {
                            try await store.unlinkSpeaker(recordingID: rid, speakerIndex: speakerIndex)
                            await loadInspectorSummaryData(for: recording)
                            await loadResolvedLabels()
                            mutationFailure = nil
                        } catch {
                            reportMutationFailure(.unlinkSpeaker, error: error)
                        }
                    }
                }
            )

            FileInspectorSection(recording: recording)
        }
        .formStyle(.grouped)
        .background(.thinMaterial)
        .navigationTitle("Inspector")
        .task(id: recording.id) {
            await loadInspectorSummaryData(for: recording)
        }
    }

    func loadInspectorSummaryData(for recording: Recording) async {
        let people = (try? await store.fetchPeople()) ?? []
        allPeople = people
        allPeopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
        if let id = recording.id {
            inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
        } else {
            inspectorPendingSuggestions = []
        }
    }

    // MARK: - Helpers

    func openSettings() {
        bridge.onOpenSettings()
    }


    func reportMutationFailure(_ action: LibraryMutationAction, error: Error) {
        mutationFailure = LibraryMutationFailure(action: action, error: error)
    }

    /// Resolved recording for the current selection, or nil when a Person is selected.
    var selectedRecording: Recording? {
        guard case .recording(let wavPath) = selection else { return nil }
        // Check search hits first (they carry the same Recording), then the
        // main recordings list.
        if let hit = libraryVM.hits.first(where: { $0.recording.wavPath == wavPath }) {
            return hit.recording
        }
        return libraryVM.recordings.first { $0.wavPath == wavPath }
    }

    /// Alias used by the toolbar buttons; identical to `selectedRecording`.
    var currentRecording: Recording? { selectedRecording }

    /// Copies the currently loaded transcript text to the system pasteboard.
    /// The headline copy action: prompt-formatted, ready for an LLM — the
    /// same blob the post-stop tray pastes. Plain transcript stays available
    /// in the share menu.
    func copyForPrompt(_ recording: Recording) {
        let blob = ExportService.promptString(
            for: recording,
            includeSummary: prefs.includeSummaryInPrompt
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blob, forType: .string)
    }

    func copyTranscript(_ recording: Recording) {
        let text = transcriptText.isEmpty ? (recording.transcriptText ?? "") : transcriptText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// True when there is any transcript source available for this recording.
    func hasTranscriptSource(_ rec: Recording) -> Bool {
        if let text = rec.transcriptText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let path = rec.txtPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Derive distinct speaker indices from the JSON sidecar via
    /// `ExportInputBuilder.build`. Returns [] for un-diarized recordings.
    func speakerIndices(for recording: Recording) -> [Int] {
        let input = ExportInputBuilder.build(from: recording)
        var seen: Set<Int> = []
        for segment in input.segments {
            if let id = segment.speaker { seen.insert(id) }
        }
        return seen.sorted()
    }

    func loadEnvelope() async {
        guard let rec = currentRecording else {
            detailEnvelope = []
            return
        }
        do {
            detailEnvelope = try await AmplitudeEnvelopeLoader.load(
                url: URL(fileURLWithPath: rec.wavPath),
                samples: 1024
            )
        } catch {
            detailEnvelope = []
        }
    }

    /// Pre-resolves speaker labels for the current selection via
    /// `RecordingStore.resolvedSpeakerName`. Covers up to 12 speaker indices —
    /// enough for any realistic meeting; the bound keeps store calls
    /// predictable. Results are cached in `resolvedSpeakerLabels` and used by
    /// `buildDisplaySegments` so Person-linked display names appear in the
    /// transcript turns.
    func loadResolvedLabels() async {
        guard let rec = currentRecording, let id = rec.id else {
            await MainActor.run { resolvedSpeakerLabels = [:] }
            return
        }
        var out: [Int: String] = [:]
        for i in 0..<12 {
            if let name = try? await store.resolvedSpeakerName(recordingID: id, speakerIndex: i) {
                out[i] = name
            }
        }
        await MainActor.run {
            resolvedSpeakerLabels = out
            // Rebuild transcript segments with the freshly-resolved labels so
            // Person-linked names appear in the transcript turns. This handles
            // the case where loadTranscript() ran before this async read
            // completed and built segments with an empty dict.
            rebuildTranscriptSegments()
        }
    }

    /// Loads `transcriptText` from cache or disk. Called on selection change.
    /// Also loads the structured .json sidecar when available so the detail
    /// pane can render per-turn timestamps instead of the flat .txt blob.
    func loadTranscript() {
        transcriptLoadError = nil
        transcriptText = ""
        transcriptSegments = []
        detailDocument = nil
        editorText = ""
        editorHighlight = nil
        editorDirty = false
        editorSaveError = nil
        lastAutosaveAt = nil
        speakerBoundaries = []
        guard let recording = selectedRecording else { return }
        titleDraft = recording.title ?? ""

        // The pane edits in place now, so it loads through the same tolerant
        // document the editor window used: .md transcript section preferred,
        // JSON joinedText fallback, word index for click-to-seek.
        let doc = TranscriptDocument.load(recording: recording)
        detailDocument = doc
        editorText = doc.initialText
        speakerBoundaries = Self.speakerTurnOffsets(in: doc.initialText)

        // Plain text for fallback / pasteboard copy.
        if let cached = recording.transcriptText, !cached.isEmpty {
            transcriptText = cached
        } else if let txtPath = recording.txtPath {
            do {
                let raw = try String(contentsOf: URL(fileURLWithPath: txtPath), encoding: .utf8)
                // OKF .md sidecars carry frontmatter + summary; show only
                // the transcript section. Legacy .txt reads pass through.
                transcriptText = OKFMarkdown.extractTranscript(from: raw) ?? raw
            } catch {
                transcriptLoadError = "Could not load transcript: \(error.localizedDescription)"
            }
        } else {
            transcriptLoadError = "No transcript file — recording may not have been transcribed."
        }

        // Structured turns (preferred render path).
        // Note: resolvedSpeakerLabels may still be loading at this point
        // (loadResolvedLabels runs concurrently); if so, segments are built
        // with an empty dict — falling back to "Speaker N+1" — and rebuilt
        // once loadResolvedLabels completes and calls rebuildTranscriptSegments.
        if let jsonPath = recording.jsonPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let session = try? decoder.decode(SessionTranscript.self, from: data) {
                transcriptSegments = Self.buildDisplaySegments(
                    session: session,
                    speakerNames: resolvedSpeakerLabels
                )
            }
        }
    }

    /// Rebuilds `transcriptSegments` for the current selection using the
    /// already-resolved `resolvedSpeakerLabels`. Called from
    /// `loadResolvedLabels()` after labels are populated so Person-linked names
    /// appear in the transcript once the async store read completes.
    @MainActor
    func rebuildTranscriptSegments() {
        guard let recording = selectedRecording,
              let jsonPath = recording.jsonPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let session = try? decoder.decode(SessionTranscript.self, from: data) {
            transcriptSegments = Self.buildDisplaySegments(
                session: session,
                speakerNames: resolvedSpeakerLabels
            )
        }
    }

    static func buildDisplaySegments(
        session: SessionTranscript,
        speakerNames: [Int: String]
    ) -> [TranscriptDisplaySegment] {
        guard !session.speakers.isEmpty, !session.words.isEmpty else { return [] }

        // First pass: assign each word to a speaker (mirrors
        // TranscriptPlainTextRenderer's algorithm so we get the same
        // SentencePiece-aware concat: "That's" tokenized as ["That", "'s"]
        // joins back to "That's" inside a single turn).
        struct AssignedWord {
            let text: String
            let startMs: Int
            let endMs: Int
            let speaker: Int
        }

        let sentencePieceStyle = session.words.contains { $0.text.first?.isWhitespace == true }
        var assigned: [AssignedWord] = []
        var lastSpeaker: Int? = nil
        for w in session.words {
            let mid = (w.startMs + w.endMs) / 2
            let s: Int
            if let containing = session.speakers.first(where: { mid >= $0.startMs && mid < $0.endMs }) {
                s = containing.speaker
            } else if let last = lastSpeaker {
                s = last
            } else {
                s = session.speakers.min { a, b in
                    distanceFromSegment(mid, segment: a) < distanceFromSegment(mid, segment: b)
                }?.speaker ?? 0
            }
            assigned.append(AssignedWord(text: w.text, startMs: w.startMs, endMs: w.endMs, speaker: s))
            lastSpeaker = s
        }

        // Smoothing pass: collapse sub-300ms speaker excursions that are
        // surrounded by the same other speaker. Catches diarizer artifacts
        // where a single token (often punctuation like "'") flips speaker
        // mid-word.
        let minRunMs = 300
        var i = 0
        while i < assigned.count {
            // Find run [i, j) of same speaker.
            var j = i + 1
            while j < assigned.count && assigned[j].speaker == assigned[i].speaker { j += 1 }
            let runDuration = assigned[j - 1].endMs - assigned[i].startMs
            let prevSpeaker = i > 0 ? assigned[i - 1].speaker : nil
            let nextSpeaker = j < assigned.count ? assigned[j].speaker : nil
            let surroundedBySame = prevSpeaker != nil && prevSpeaker == nextSpeaker && prevSpeaker != assigned[i].speaker
            if runDuration < minRunMs && surroundedBySame, let host = prevSpeaker {
                for k in i..<j {
                    assigned[k] = AssignedWord(
                        text: assigned[k].text,
                        startMs: assigned[k].startMs,
                        endMs: assigned[k].endMs,
                        speaker: host
                    )
                }
            }
            i = j
        }

        // Second pass: group consecutive same-speaker words into turns,
        // concatenating with the right strategy for the tokenizer style.
        var segments: [TranscriptDisplaySegment] = []
        var currentSpeaker: Int? = nil
        var currentStartMs: Int = 0
        var bucket = ""

        func flush() {
            let trimmed = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let speaker = currentSpeaker {
                let name = speakerNames[speaker] ?? "Speaker \(speaker + 1)"
                segments.append(TranscriptDisplaySegment(
                    speaker: speaker,
                    speakerName: name,
                    startSec: currentStartMs / 1000,
                    text: trimmed
                ))
            }
            bucket = ""
        }

        for w in assigned {
            if w.speaker != currentSpeaker {
                flush()
                currentSpeaker = w.speaker
                currentStartMs = w.startMs
            }
            if sentencePieceStyle {
                bucket += w.text
            } else if bucket.isEmpty {
                bucket = w.text
            } else {
                bucket += " " + w.text
            }
        }
        flush()
        return segments
    }

    static func distanceFromSegment(_ point: Int, segment: SpeakerSegment) -> Int {
        if point < segment.startMs { return segment.startMs - point }
        if point >= segment.endMs  { return point - segment.endMs + 1 }
        return 0
    }

    /// Observe DB changes to the selected recording so the detail pane updates
    /// when the recording is renamed or its transcript is edited.
    func observeRecording(recording: Recording) async {
        guard let id = recording.id else { return }
        for await latest in store.observe(id: id) {
            guard let latest else { continue }
            if transcriptText.isEmpty, let cached = latest.transcriptText, !cached.isEmpty {
                transcriptText = cached
            }
            // libraryVM.recordings is driven by ValueObservation, so the list
            // updates automatically; selectedRecording re-derives from it.
        }
    }
}


/// Accumulates URLs delivered by NSItemProvider completion handlers (which
/// run on arbitrary queues) and fires `completion` on the main queue once
/// every provider has reported. Lock-guarded; @unchecked Sendable is safe
/// because all mutable state is touched only under the lock.
private final class DropURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var remaining: Int
    private let completion: @MainActor ([URL]) -> Void

    init(expected: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        self.remaining = expected
        self.completion = completion
    }

    func add(_ url: URL?) {
        let finished: [URL]?
        lock.lock()
        if let url { urls.append(url) }
        remaining -= 1
        finished = remaining == 0 ? urls : nil
        lock.unlock()
        if let finished {
            let completion = completion
            Task { @MainActor in completion(finished) }
        }
    }
}
