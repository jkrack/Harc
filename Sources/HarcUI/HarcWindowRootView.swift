import SwiftUI
import Foundation
import HarcStore
import HarcExport
import HarcClient
import HarcCore
import HarcContext
import HarcModels
import HarcSummarize
import AppKit

// MARK: - Notifications

public extension NSNotification.Name {
    /// Posted by AppDelegate when the user invokes "open library + focus search".
    /// `HarcWindowRootView` observes this to activate its search field.
    static let harcLibraryFocusSearch = NSNotification.Name("HarcLibraryFocusSearch")
    /// Posted when notes are changed outside the library window, for example
    /// when AppDelegate appends a stopped recording transcript to an active note.
    static let harcNotesDidChange = NSNotification.Name("HarcNotesDidChange")
}


// MARK: - HarcWindowRootView

/// Main window root view. Hosts a `NavigationSplitView` with a recording-list
/// sidebar (grouped by date / pinned), a transcript detail pane, and an
/// inspector panel showing speaker and file metadata.
///
/// Toolbar actions (Edit, Export, Delete, recording pill) are wired in.
/// This view is hosted by `HarcWindowController`.
public struct HarcWindowRootView: View {
    static let noteWritingModes: [NoteMarkdownEditorMode] = [.live, .source]

    @ObservedObject var libraryVM: LibraryViewModel
    @ObservedObject var recordingState: RecordingState
    @ObservedObject var bridge: HarcAppBridge
    @ObservedObject var peopleVM: PeopleViewModel

    let store: RecordingStore
    let reIDService: SpeakerReIDService
    let summarizerService: SummarizerService
    let knowledgeIndexer: KnowledgeIndexer?
    let onEdit: (Recording) -> Void
    let onDelete: (Recording) -> Void

    // MARK: View state

    /// Primary selection — `.recording(wavPath:)` for recordings, `.person(id:)` for People.
    @State var selection: LibrarySelection?
    @State var mode: HarcLibraryMode = .library
    @State var wikiSection: WikiSection = .overview
    @State var selectedWikiPageID: String?
    @State var wikiPages: [WikiPage] = []
    @State var wikiLoadError: String?
    @State var reviewProposals: [WikiReviewProposal] = []
    @State var selectedReviewProposalID: String?
    @State var reviewLoadError: String?
    @State var reviewActionInFlight: Set<String> = []
    @State var reviewActionStatus: [String: String] = [:]
    @State var reviewApprovedPageID: [String: String] = [:]
    @State var reviewMarkdownDrafts: [String: String] = [:]
    @State var reviewGenerationStatus: String?
    @State var sourceScanStatus: String?
    @State var mutationFailure: LibraryMutationFailure?
    @State var inspectorOpen: Bool = false
    @State var showingAddPerson = false

    // Transcript text is loaded lazily on selection change to avoid
    // synchronous disk I/O in the view body.
    @State var transcriptText: String = ""
    /// Set when the user picks Delete from a sidebar context menu — drives
    /// the destructive confirmation alert.
    @State var pendingDeleteRecording: Recording? = nil
    @State var pendingDeleteNote: Note? = nil
    /// When the .json sidecar is available, we render structured turns
    /// (timestamp + speaker + text) instead of the flat .txt blob.
    @State var transcriptSegments: [TranscriptDisplaySegment] = []
    @State var transcriptLoadError: String? = nil
    @State var transcriptFindVisible = false
    @State var transcriptSearchText = ""
    @State var transcriptSearchIndex = 0
    @FocusState var transcriptSearchFocused: Bool
    @State var detailEnvelope: [Float] = []
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
    @State var contextCopyStatus: String?
    @State var contextCopyInFlight = false
    @State var contextPackScope: ContextPackScope = .topResults
    @State var conversationAnswer: String?
    @State var conversationStatus: String?
    @State var conversationInFlight = false
    @State var notes: [Note] = []
    @State var didLoadNotes = false
    @State var noteSearchResults: [Note] = []
    @State var notesError: String?
    @State var noteTitleDraft: String = ""
    @State var noteBodyDraft: String = ""
    @State var noteDirty: Bool = false
    @State var noteSaving: Bool = false
    @State var noteSavedAt: Date?
    @State var noteDraftSession = NoteDraftSession()
    @State var noteLastLoadedUpdatedAt: Date?
    @State var noteSaveError: String?
    @State var noteSaveConflict: NoteSaveConflict?
    @State var captioningAttachmentIDs: Set<String> = []
    @State var unresolvedBarePersonMentions: [String] = []
    @State var noteEditorMode: NoteMarkdownEditorMode = .live
    @State var noteWritingMode: NoteMarkdownEditorMode = .live
    @State var noteMentionPeople: [Person] = []
    @State var linkedNotes: [Note] = []
    @State var linkedNotesError: String?
    @State var notesExpanded = true
    @State var expandedNoteBuckets: Set<String> = []
    @State var knownNoteBucketIDs: Set<String> = []
    @State var projectsExpanded = false
    @State var peopleExpanded = false
    @State var recordingsExpanded = true
    @State var sidebarSectionOrder: [LibrarySidebarSection] = LibrarySidebarSection.defaultOrder
    @State var restoredSelection: LibrarySelection?
    @State var exportRecording: Recording?
    @State var exportDraft = RecordingExportDraft(includeSummary: true)
    @State var showingNewProject = false
    @State var newProjectName = ""
    @State var newProjectError: String?
    @State var newProjectSaving = false

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
        knowledgeIndexer: KnowledgeIndexer? = nil,
        onEdit: @escaping (Recording) -> Void,
        onDelete: @escaping (Recording) -> Void
    ) {
        self.libraryVM = libraryVM
        self.recordingState = recordingState
        self.bridge = bridge
        self.peopleVM = peopleVM
        self.store = store
        self.reIDService = reIDService
        self.summarizerService = summarizerService
        self.knowledgeIndexer = knowledgeIndexer
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    // MARK: Body

    var modeSwitcher: some View {
        Picker("Mode", selection: $mode) {
            ForEach(HarcLibraryMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help("Switch between Library, Wiki, and Review")
        .accessibilityIdentifier("harc.library.modeSwitcher")
    }

    var pendingDeleteRecordingBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteRecording != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteRecording = nil }
            }
        )
    }

    var pendingDeleteNoteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteNote != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteNote = nil }
            }
        )
    }

    var noteIDsForNavigation: [String] {
        notes.map(\.id)
    }

    var recordingPathsForNavigation: [String] {
        libraryVM.recordings.map(\.wavPath)
    }

    var personIDsForNavigation: [Int64] {
        peopleVM.people.map { $0.person.id }
    }

    var navigationValidationToken: String {
        [
            noteIDsForNavigation.joined(separator: "\u{1f}"),
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
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: selection) { oldSelection, _ in
            flushOutgoingNoteIfNeeded(oldSelection)
            persistNavigationSnapshot()
            loadTranscript()
            loadSelectedNoteDraft()
            Task { await loadEnvelope() }
            Task { await loadResolvedLabels() }
        }
        .onChange(of: prefs.notesPath) { _, _ in
            Task { await loadNotes() }
        }
        .onChange(of: libraryVM.filter) { _, _ in
            seedDefaultNoteBucketExpansion()
        }
        .onChange(of: mode) { _, newMode in
            persistNavigationSnapshot()
            switch newMode {
            case .library:
                break
            case .wiki:
                Task { await loadWikiPages() }
            case .review:
                Task { await loadReviewProposals() }
            }
        }
        .onChange(of: navigationValidationToken) { _, _ in restoreOrValidateSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .harcNotesDidChange)) { _ in
            Task { await loadNotes(resetDraft: !noteDirty) }
        }
        .onChange(of: libraryVM.searchText) { _, _ in
            Task { await searchNotes() }
        }
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
        .alert(
            "Delete note?",
            isPresented: pendingDeleteNoteBinding,
            presenting: pendingDeleteNote
        ) { note in
            Button("Delete", role: .destructive) {
                archiveNote(note)
            }
            Button("Cancel", role: .cancel) { pendingDeleteNote = nil }
        } message: { note in
            Text("\u{201C}\(note.title)\u{201D} will be removed from the Notes list. The Markdown file is archived, not permanently deleted.")
        }
        .sheet(isPresented: $showingAddPerson) {
            AddPersonSheet { name in
                Task {
                    do {
                        _ = try await store.createPerson(displayName: name)
                        await loadNoteMentionPeople()
                        showingAddPerson = false
                        mutationFailure = nil
                    } catch {
                        reportMutationFailure(.addPerson(name), error: error)
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(
                name: $newProjectName,
                errorMessage: newProjectError,
                isSaving: newProjectSaving,
                onCancel: {
                    showingNewProject = false
                    newProjectName = ""
                    newProjectError = nil
                    newProjectSaving = false
                },
                onCreate: {
                    createProject(named: newProjectName)
                }
            )
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
        Task {
            await loadInitialData()
        }
    }

    func handleDisappear() {
        noteDraftSession.cancelAutosave()
        libraryVM.stop()
        peopleVM.stop()
    }

    func loadInitialData() async {
        await loadNotes()
        await loadNoteMentionPeople()
        await loadWikiPages()
        await loadReviewProposals()
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
            prompt: "Search titles, transcripts, and notes"
        )
        .toolbar {
            // Leading: compound recording pill — visible only while recording.
            ToolbarItem(placement: .navigation) {
                if recordingState.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(HarcBrand.live)
                            .frame(width: 8, height: 8)
                        LiveWaveformView(
                            history: bridge.amplitudeHistory,
                            size: .pill,
                            isActive: true,
                            tint: WavePalette.center
                        )
                        .frame(width: 60, height: 16)
                        Text("Recording")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(HarcBrand.live), in: Capsule())
                    .overlay(Capsule().stroke(HarcBrand.live.opacity(0.4), lineWidth: 1))
                }
            }

            // Trailing group: Copy / Edit / Export / Delete + Inspector toggle.
            ToolbarItemGroup {
                Button {
                    if let rec = currentRecording { copyTranscript(rec) }
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(currentRecording == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    if let rec = currentRecording { onEdit(rec) }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .disabled(currentRecording == nil)

                Button {
                    if let rec = currentRecording { presentExport(rec) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(currentRecording == nil)

                Button(role: .destructive) {
                    if let rec = currentRecording { onDelete(rec) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(currentRecording == nil)

                Spacer()

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
        inspectorPendingSuggestions.count + linkedNotes.count
    }

    // MARK: - Library footer (status bar)

    var libraryFooter: some View {
        HStack(spacing: 0) {
            Text(footerCountAndStorage)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 16)
            footerStackHardware
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    var footerStackHardware: some View {
        HStack(spacing: 8) {
            Text("\(HardwareInfo.appleSiliconDisplayName) · Neural Engine")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.secondary)
            Text("·").foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            Text("parakeet-tdt-0.6b-v3")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.secondary)
            Text("·").foregroundStyle(Color(nsColor: .quaternaryLabelColor))
            Text("LOCAL")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(Color.green)
        }
    }

    var footerCountAndStorage: String {
        let isSearching = !libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let count = isSearching ? libraryVM.hits.count : libraryVM.recordings.count
        let label = count == 1 ? "recording" : "recordings"
        return "\(count) \(label) · \(footerStorageString)"
    }

    var footerStorageString: String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: libraryVM.totalBytes)
    }

    // MARK: - Sidebar

    @ViewBuilder
    var sidebar: some View {
        VStack(spacing: 0) {
            modeSwitcher
            Divider()
            switch mode {
            case .library:
                calendarHeader
                Divider()
                Group {
                    if libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        groupedList
                    } else {
                        searchResultsList
                    }
                }
                .listStyle(.sidebar)
            case .wiki:
                wikiSidebar
            case .review:
                reviewSidebar
            }
        }
        .navigationTitle(mode.rawValue)
        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 480)
    }

    var wikiSidebar: some View {
        List(selection: $wikiSection) {
            Section("Wiki") {
                ForEach(WikiSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }

            if !wikiPages.filter({ $0.section == wikiSection }).isEmpty {
                Section("Pages") {
                    ForEach(wikiPages.filter { $0.section == wikiSection }) { page in
                        Button {
                            selectedWikiPageID = page.id
                        } label: {
                            Label(page.title, systemImage: "doc.text")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Sources") {
                if prefs.sourceRoots.isEmpty {
                    Text("No source folders connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prefs.sourceRoots) { root in
                        Label(root.displayName, systemImage: root.kind == .repository ? "chevron.left.forwardslash.chevron.right" : "folder")
                            .help(root.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    var reviewSidebar: some View {
        let grouping = ReviewProposalGrouping.make(from: reviewProposals)
        return List(selection: $selectedReviewProposalID) {
            Section("Queue") {
                ForEach(grouping.buckets) { bucket in
                    reviewBucket(bucket)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Calendar header

    var calendarHeader: some View {
        VStack(spacing: 6) {
            MonthCalendarView(
                month: libraryVM.calendarMonth,
                selectedDay: selectedFilterDay,
                daysWithRecordings: libraryVM.daysWithRecordings,
                daysWithNotes: daysWithNotes(inMonthContaining: libraryVM.calendarMonth),
                onPrevMonth: { libraryVM.advanceMonth(by: -1) },
                onNextMonth: { libraryVM.advanceMonth(by: 1) },
                onSelectDay: { day in
                    // Toggle: clicking the already-selected day clears the filter.
                    if let current = selectedFilterDay,
                       Calendar.current.isDate(current, inSameDayAs: day) {
                        libraryVM.filter = .all
                    } else {
                        libraryVM.filter = .day(day)
                    }
                }
            )
            if let activeDay = selectedFilterDay {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Filtered: \(formatFilterDay(activeDay))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show all") { libraryVM.filter = .all }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    var contextScopeDescription: String {
        let noteCount = noteSearchResults.count
        let recordingCount = libraryVM.hits.count
        switch contextPackScope {
        case .topResults:
            return "Top 8 ranked matches from notes and recordings."
        case .visibleResults:
            return "\(noteCount) note\(noteCount == 1 ? "" : "s") and \(recordingCount) recording\(recordingCount == 1 ? "" : "s") currently visible."
        case .selectedResult:
            switch selection {
            case .note:
                return "Selected note only."
            case .recording:
                return "Selected recording only."
            default:
                return "Select a note or recording first."
            }
        }
    }

    var selectedFilterDay: Date? {
        if case .day(let d) = libraryVM.filter { return d }
        return nil
    }

    func daysWithNotes(inMonthContaining month: Date) -> Set<Date> {
        NoteCalendarIndex.daysWithNotes(notes, inMonthContaining: month)
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
            Section {
                captureSidebarActions
            }

            ForEach(sidebarSectionOrder) { section in
                sidebarSection(section)
            }
            .onMove(perform: moveSidebarSections)
        }
    }

    var captureSidebarActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                bridge.onStartStop()
            } label: {
                HStack(spacing: 8) {
                    if isRecordingActionBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: recordingActionIconName)
                    }
                    Text(recordingActionTitle)
                        .fontWeight(.semibold)
                }
                .frame(minWidth: 118, alignment: .center)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .tint(recordingState.isRecording ? HarcBrand.live : Color.accentColor)
            .disabled(isRecordingActionBusy)
            .accessibilityIdentifier("harc.library.capture.recordButton")
            if let recordingActionStatusText {
                Text(recordingActionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Use the menu bar icon or configure the global hotkey in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
                .font(.caption)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
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

    var recordingActionIconName: String {
        if bridge.recordingStopInFlight || isIdentifyingStoppedRecording { return "hourglass" }
        return recordingState.isRecording ? "stop.circle.fill" : "record.circle"
    }

    var recordingActionStatusText: String? {
        if bridge.recordingStopInFlight {
            return "Finalizing audio and transcript."
        }
        if isIdentifyingStoppedRecording {
            return "Identifying speakers and saving the recording."
        }
        return nil
    }

    @ViewBuilder
    func sidebarSection(_ section: LibrarySidebarSection) -> some View {
        switch section {
        case .recordings:
            DisclosureGroup(isExpanded: persistedExpansionBinding(.recordings)) {
                recordingSidebarList
            } label: {
                sidebarSectionHeader(section)
            }
        case .notes:
            DisclosureGroup(isExpanded: persistedExpansionBinding(.notes)) {
                noteSidebarList
            } label: {
                sidebarSectionHeader(section)
            }
        case .projects:
            DisclosureGroup(isExpanded: persistedExpansionBinding(.projects)) {
                projectSidebarList
            } label: {
                sidebarSectionHeader(section)
            }
        case .people:
            DisclosureGroup(isExpanded: persistedExpansionBinding(.people)) {
                peopleSidebarList
            } label: {
                sidebarSectionHeader(section)
            }
        }
    }

    func sidebarSectionHeader(_ section: LibrarySidebarSection) -> some View {
        HStack(spacing: 6) {
            Label(section.sidebarTitle, systemImage: section.sidebarIconName)
            Spacer(minLength: 4)
        }
        .contextMenu {
            Button("Move Up") { moveSidebarSection(section, by: -1) }
                .disabled(!canMoveSidebarSection(section, by: -1))
            Button("Move Down") { moveSidebarSection(section, by: 1) }
                .disabled(!canMoveSidebarSection(section, by: 1))
            Divider()
            Button("Reset Sidebar Order") {
                sidebarSectionOrder = LibrarySidebarSection.defaultOrder
                persistNavigationSnapshot()
            }
        }
    }

    func canMoveSidebarSection(_ section: LibrarySidebarSection, by offset: Int) -> Bool {
        guard let index = sidebarSectionOrder.firstIndex(of: section) else { return false }
        return sidebarSectionOrder.indices.contains(index + offset)
    }

    func moveSidebarSection(_ section: LibrarySidebarSection, by offset: Int) {
        guard let index = sidebarSectionOrder.firstIndex(of: section) else { return }
        let destination = index + offset
        guard sidebarSectionOrder.indices.contains(destination) else { return }
        sidebarSectionOrder.swapAt(index, destination)
        persistNavigationSnapshot()
    }

    func moveSidebarSections(from source: IndexSet, to destination: Int) {
        sidebarSectionOrder.move(fromOffsets: source, toOffset: destination)
        sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(sidebarSectionOrder)
        persistNavigationSnapshot()
    }

    @ViewBuilder
    var recordingSidebarList: some View {
        if libraryVM.recordings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                EmptyStateView(
                    icon: "waveform.slash",
                    title: "No recordings yet",
                    subtitle: "Start a capture here, from the menu bar icon, or set a global hotkey in Settings."
                )
                HStack(spacing: 8) {
                    Button("Record") { bridge.onStartStop() }
                        .buttonStyle(.borderedProminent)
                    Button("Settings") { openSettings() }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
        } else {
            let pinned = libraryVM.recordings.filter(\.pinned)
            if !pinned.isEmpty {
                Text("Pinned")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(pinned) { rec in
                    recordingLabel(rec)
                }
            }

            let unpinned = libraryVM.recordings.filter { !$0.pinned }
            let buckets = Self.dateBuckets(from: unpinned)
            ForEach(buckets, id: \.label) { bucket in
                Text(bucket.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(bucket.recordings) { rec in
                    recordingLabel(rec)
                }
            }
        }
    }

    @ViewBuilder
    var projectSidebarList: some View {
        let projects = inferredProjectNames()
        Button {
            newProjectName = ""
            newProjectError = nil
            newProjectSaving = false
            showingNewProject = true
        } label: {
            Label("New Project", systemImage: "folder.badge.plus")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("harc.library.project.new")

        if projects.isEmpty {
            Text("No projects yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(projects, id: \.self) { project in
                projectLabel(project)
            }
        }
    }

    @ViewBuilder
    var peopleSidebarList: some View {
        ForEach(peopleVM.people) { item in
            HStack(spacing: 8) {
                PersonAvatar(displayName: item.person.displayName, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.person.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if let lastSeen = item.lastSeen {
                        Text(Self.relativeDate(lastSeen))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if item.suggestionCount > 0 {
                    Text("\(item.suggestionCount)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.25)))
                        .foregroundStyle(.primary)
                }
            }
            .tag(LibrarySelection.person(id: item.person.id))
        }
        Button {
            showingAddPerson = true
        } label: {
            Label("Add person\u{2026}", systemImage: "person.crop.circle.badge.plus")
                .font(.subheadline)
        }
        .buttonStyle(.plain)
    }

    enum SidebarExpansionGroup {
        case notes
        case projects
        case people
        case recordings
    }

    func expansionGroup(for section: LibrarySidebarSection) -> SidebarExpansionGroup {
        switch section {
        case .recordings: return .recordings
        case .notes: return .notes
        case .projects: return .projects
        case .people: return .people
        }
    }

    func persistedExpansionBinding(_ group: SidebarExpansionGroup) -> Binding<Bool> {
        Binding(
            get: {
                switch group {
                case .notes: return notesExpanded
                case .projects: return projectsExpanded
                case .people: return peopleExpanded
                case .recordings: return recordingsExpanded
                }
            },
            set: { newValue in
                switch group {
                case .notes: notesExpanded = newValue
                case .projects: projectsExpanded = newValue
                case .people: peopleExpanded = newValue
                case .recordings: recordingsExpanded = newValue
                }
                persistNavigationSnapshot()
            }
        )
    }

    @ViewBuilder
    var noteSidebarList: some View {
        let grouping = NoteSidebarGrouping.make(notes: notes, selectedDay: selectedFilterDay)

        Button {
            createBlankNote()
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
                .font(.subheadline)
        }
        .buttonStyle(.plain)

        if grouping.isEmpty {
            Text(notesError ?? "No notes yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if !grouping.pinned.isEmpty {
                DisclosureGroup(isExpanded: noteBucketBinding("pinned")) {
                    ForEach(grouping.pinned) { note in
                        noteLabel(note)
                    }
                } label: {
                    noteBucketLabel("Pinned", count: grouping.pinned.count)
                }
            }

            if !grouping.recent.isEmpty {
                DisclosureGroup(isExpanded: noteBucketBinding("recent")) {
                    ForEach(grouping.recent) { note in
                        noteLabel(note)
                    }
                } label: {
                    noteBucketLabel("Recent", count: grouping.recent.count)
                }
            }

            ForEach(grouping.buckets) { bucket in
                DisclosureGroup(isExpanded: noteBucketBinding(bucket.id)) {
                    ForEach(bucket.notes) { note in
                        noteLabel(note)
                    }
                } label: {
                    noteBucketLabel(bucket.label, count: bucket.notes.count)
                }
            }
        }
    }

    func noteBucketLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
        }
        .padding(.top, 4)
    }

    func noteBucketBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedNoteBuckets.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedNoteBuckets.insert(id)
                } else {
                    expandedNoteBuckets.remove(id)
                }
                knownNoteBucketIDs.insert(id)
                persistNavigationSnapshot()
            }
        )
    }

    func seedDefaultNoteBucketExpansion() {
        let grouping = NoteSidebarGrouping.make(notes: notes, selectedDay: selectedFilterDay)
        var currentIDs = Set(grouping.buckets.map(\.id))
        if !grouping.pinned.isEmpty { currentIDs.insert("pinned") }
        if !grouping.recent.isEmpty { currentIDs.insert("recent") }
        let newIDs = currentIDs.subtracting(knownNoteBucketIDs)
        expandedNoteBuckets.formUnion(grouping.defaultExpandedBucketIDs.intersection(newIDs))
        knownNoteBucketIDs.formUnion(currentIDs)
        expandedNoteBuckets.formIntersection(currentIDs)
    }

    func restoreNavigationSnapshot() {
        let snapshot = LibraryNavigationStateStore.load()
        if let restoredMode = HarcLibraryMode(rawValue: snapshot.modeRawValue) {
            mode = restoredMode
        }
        notesExpanded = snapshot.notesExpanded
        projectsExpanded = snapshot.projectsExpanded
        peopleExpanded = snapshot.peopleExpanded
        recordingsExpanded = snapshot.recordingsExpanded
        sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(snapshot.sidebarSectionOrder)
        expandedNoteBuckets = Set(snapshot.expandedNoteBuckets)
        knownNoteBucketIDs = Set(snapshot.knownNoteBuckets)
        restoredSelection = snapshot.selection?.librarySelection
        if let restoredSelection {
            selection = restoredSelection
        }
    }

    func persistNavigationSnapshot() {
        LibraryNavigationStateStore.save(LibraryNavigationSnapshot(
            modeRawValue: mode.rawValue,
            selection: selection.map(PersistedLibrarySelection.init),
            notesExpanded: notesExpanded,
            projectsExpanded: projectsExpanded,
            peopleExpanded: peopleExpanded,
            recordingsExpanded: recordingsExpanded,
            sidebarSectionOrder: sidebarSectionOrder,
            expandedNoteBuckets: expandedNoteBuckets.sorted(),
            knownNoteBuckets: knownNoteBucketIDs.sorted()
        ))
    }

    func restoreOrValidateSelection() {
        guard didLoadNotes else { return }
        let candidate = restoredSelection ?? selection
        let resolved = LibraryNavigationResolver.resolvedSelection(
            restored: candidate,
            noteIDs: Set(notes.map(\.id)),
            recordingPaths: Set(libraryVM.recordings.map(\.wavPath)),
            personIDs: Set(peopleVM.people.map { $0.person.id }),
            projectNames: Set(inferredProjectNames()),
            fallbackNoteID: notes.first?.id,
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
        } else if libraryVM.hits.isEmpty && noteSearchResults.isEmpty {
            List {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    subtitle: "No titles, transcripts, or notes matched \u{201C}\(libraryVM.searchText)\u{201D}."
                )
            }
        } else {
            List(selection: $selection) {
                contextSearchHeader
                if !noteSearchResults.isEmpty {
                    Section("Notes") {
                        ForEach(noteSearchResults) { note in
                            noteLabel(note)
                        }
                    }
                }
                if !libraryVM.hits.isEmpty {
                    Section("Recordings") {
                        ForEach(libraryVM.hits) { hit in
                            TranscriptHitRow(hit: hit, onEdit: {
                                onEdit(hit.recording)
                            })
                            .tag(LibrarySelection.recording(wavPath: hit.recording.wavPath))
                            .contextMenu { contextMenu(for: hit.recording) }
                        }
                    }
                }
            }
        }
    }

    var contextSearchHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(Color.accentColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Context Pack")
                        .font(.headline)
                    Text("Copy matching evidence, summaries, action items, and sources as Markdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    copySearchContext()
                } label: {
                    Label(
                        contextCopyInFlight ? "Building" : "Copy Context",
                        systemImage: contextCopyInFlight ? "hourglass" : "doc.on.clipboard"
                    )
                }
                .disabled(contextCopyInFlight)

                Button {
                    answerSearchContext()
                } label: {
                    Label(
                        conversationInFlight ? "Answering" : "Ask",
                        systemImage: conversationInFlight ? "hourglass" : "bubble.left.and.text.bubble.right"
                    )
                }
                .disabled(conversationInFlight)
            }
            HStack(spacing: 8) {
                Picker("Scope", selection: $contextPackScope) {
                    ForEach(ContextPackScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(contextCopyInFlight || conversationInFlight)

                Text(contextScopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            if !modelStore.state(of: prefs.activeSummarizerID).isInstalled {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(.secondary)
                    Text("Ask needs \(ModelCatalog.descriptor(for: prefs.activeSummarizerID)?.displayName ?? "the active model").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Models") { openSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let contextCopyStatus {
                Text(contextCopyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let conversationStatus {
                Text(conversationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let conversationAnswer {
                Text(conversationAnswer)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 8)
    }

    /// Recording row for use inside a `List(selection:)`. The tag is `wavPath`
    /// to match `selection`.
    func recordingLabel(_ rec: Recording) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                .foregroundStyle(rec.pinned ? Color.purple : Color.accentColor)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let endedAt = rec.endedAt {
                    Text(Self.formatDuration(from: rec.startedAt, to: endedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44, alignment: .topLeading)
        .tag(LibrarySelection.recording(wavPath: rec.wavPath))
        .accessibilityIdentifier("harc.library.recording.\(rec.id.map(String.init) ?? rec.wavPath)")
        .contentShape(Rectangle())
        .onTapGesture {
            selection = .recording(wavPath: rec.wavPath)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selection = .recording(wavPath: rec.wavPath)
                onEdit(rec)
            }
        )
        .contextMenu { contextMenu(for: rec) }
    }

    func noteLabel(_ note: Note) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.body)
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: note.pinned ? "pin.fill" : "note.text")
                .foregroundStyle(note.pinned ? Color.purple : Color.accentColor)
        }
        .tag(LibrarySelection.note(id: note.id))
        .accessibilityIdentifier("harc.library.note.\(note.id)")
        .contextMenu {
            Button("Open in Harc") { selection = .note(id: note.id) }
            Button(note.pinned ? "Unpin Note" : "Pin Note") {
                toggleNotePin(note)
            }
            Divider()
            Button("Open Markdown File") { NSWorkspace.shared.open(note.fileURL) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
            }
            Divider()
            Button("Delete Note", role: .destructive) {
                pendingDeleteNote = note
            }
        }
    }

    func projectLabel(_ project: String) -> some View {
        let counts = projectCounts(for: project)
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(project)
                    .font(.body)
                    .lineLimit(1)
                Text(projectSubtitle(noteCount: counts.notes, recordingCount: counts.recordings))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
        }
        .tag(LibrarySelection.project(name: project))
        .accessibilityIdentifier("harc.library.project.\(normalizeWikilinkLabel(project))")
        .contextMenu {
            Button("New Note in Project") {
                createNote(forProject: project)
            }
            Button("Copy Project Mention") {
                copyProjectMention(project)
            }
        }
    }

    func projectSubtitle(noteCount: Int, recordingCount: Int) -> String {
        let noteLabel = "\(noteCount) note\(noteCount == 1 ? "" : "s")"
        let recordingLabel = "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")"
        return "\(noteLabel) · \(recordingLabel)"
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
        Button("Open in Editor…") { onEdit(rec) }
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

            linkedNotesSection(recording: recording)

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
        await loadLinkedNotes(for: recording)
    }

    func linkedNotesSection(recording: Recording) -> some View {
        Section("Notes") {
            if linkedNotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No notes linked to this recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        createNote(for: recording)
                    } label: {
                        Label("New note from this recording", systemImage: "square.and.pencil")
                    }
                }
            } else {
                ForEach(linkedNotes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !note.preview.isEmpty {
                            Text(note.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(note.updatedAt, style: .relative)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .onTapGesture(count: 2) {
                        selection = .note(id: note.id)
                        loadSelectedNoteDraft()
                    }
                    .contextMenu {
                        Button("Open in Harc") {
                            selection = .note(id: note.id)
                            loadSelectedNoteDraft()
                        }
                        Button("Open Markdown File") {
                            NSWorkspace.shared.open(note.fileURL)
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
                        }
                    }
                }

                Button {
                    createNote(for: recording)
                } label: {
                    Label("New note from this recording", systemImage: "plus")
                }
            }

            if let linkedNotesError {
                Text(linkedNotesError)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }

    func loadLinkedNotes(for recording: Recording) async {
        do {
            linkedNotes = try await NoteStore(rootURL: prefs.notesURL).fetchLinked(to: recording)
            linkedNotesError = nil
        } catch {
            linkedNotes = []
            linkedNotesError = error.localizedDescription
        }
    }

    func createNote(for recording: Recording) {
        Task {
            do {
                let note = try await NoteStore(rootURL: prefs.notesURL).create(for: recording)
                linkedNotes = try await NoteStore(rootURL: prefs.notesURL).fetchLinked(to: recording)
                await loadNotes()
                mutationFailure = nil
                selection = .note(id: note.id)
                noteTitleDraft = note.title
                setNoteBodyDraft(note.body)
                noteDirty = false
                linkedNotesError = nil
            } catch {
                linkedNotesError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    func openSettings() {
        bridge.onOpenSettings()
    }

    var selectedNote: Note? {
        guard case .note(let id) = selection else { return nil }
        return notes.first(where: { $0.id == id })
    }

    func loadNotes(resetDraft: Bool = true) async {
        do {
            notes = try await NoteStore(rootURL: prefs.notesURL).fetchAll()
            didLoadNotes = true
            notesError = nil
            seedDefaultNoteBucketExpansion()
            await searchNotes()
            restoreOrValidateSelection()
            if resetDraft {
                loadSelectedNoteDraft()
            }
        } catch {
            notes = []
            didLoadNotes = true
            notesError = error.localizedDescription
        }
    }

    func searchNotes() async {
        let query = libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            noteSearchResults = []
            return
        }
        do {
            noteSearchResults = try await NoteStore(rootURL: prefs.notesURL).search(query: query)
        } catch {
            noteSearchResults = []
            notesError = error.localizedDescription
        }
    }

    func loadWikiPages() async {
        do {
            wikiPages = try await HarcWikiStore(rootURL: prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true))
                .fetchPages()
            wikiLoadError = nil
            if selectedWikiPageID == nil {
                selectedWikiPageID = wikiPages.first(where: { $0.section == wikiSection })?.id
            }
        } catch {
            wikiPages = []
            wikiLoadError = error.localizedDescription
        }
    }

    func loadReviewProposals() async {
        do {
            reviewProposals = try await WikiReviewStore(
                fileURL: prefs.notesURL.deletingLastPathComponent()
                    .appendingPathComponent("Wiki/.review/proposals.json")
            ).fetchAll()
            reviewLoadError = nil
            if selectedReviewProposalID == nil {
                selectedReviewProposalID = reviewProposals.first(where: { $0.status == .pending || $0.status == .edited })?.id
            }
        } catch {
            reviewProposals = []
            reviewLoadError = error.localizedDescription
        }
    }

    func scanConnectedSources() async {
        sourceScanStatus = "Scanning source folders..."
        var scanSummary = SourceScanRunSummary(perSourceLimit: prefs.sourceScanLimit)
        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )

        do {
            for root in prefs.sourceRoots {
                let documents = try LocalSourceScanner.scan(root: root)
                scanSummary.discoveredCount += documents.count
                let limited = SourceScanRunSummary.limitedBatch(documents, limit: prefs.sourceScanLimit)
                let scanBatch = limited.batch
                scanSummary.scannedCount += scanBatch.count
                scanSummary.skippedCount += limited.skippedCount
                for document in scanBatch {
                    if let knowledgeIndexer {
                        let knowledgeKind: KnowledgeSourceKind = root.kind == .repository ? .repoFile : .rawFile
                        try await knowledgeIndexer.index(
                            sourceDocument: document,
                            sourceKind: knowledgeKind
                        )
                        scanSummary.indexedCount += 1
                    }
                }
                for proposal in SourceWikiProposalGenerator.proposals(for: root, documents: scanBatch) {
                    _ = try await reviewStore.upsertIfReviewable(proposal)
                    scanSummary.proposalCount += 1
                }
            }
            sourceScanStatus = scanSummary.statusText
            await loadReviewProposals()
            mode = .review
        } catch {
            sourceScanStatus = error.localizedDescription
        }
    }

    func generateReviewFromLibrary() async {
        reviewGenerationStatus = "Generating review proposals..."
        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )

        do {
            let latestNotes = notes.isEmpty ? try await NoteStore(rootURL: prefs.notesURL).fetchAll() : notes
            let proposals = LibraryReviewProposalGenerator.proposals(
                recordings: libraryVM.recordings,
                notes: latestNotes,
                maxRecordings: 12,
                maxNotes: 20
            )
            var reviewableCount = 0
            var skippedCount = 0
            for proposal in proposals {
                let saved = try await reviewStore.upsertIfReviewable(proposal)
                if saved.status == .approved || saved.status == .dismissed {
                    skippedCount += 1
                } else {
                    reviewableCount += 1
                }
            }
            reviewGenerationStatus = "Generated \(reviewableCount) review proposals. Skipped \(skippedCount) already resolved."
            await loadReviewProposals()
            mode = .review
        } catch {
            reviewGenerationStatus = "Generate Review failed: \(error.localizedDescription)"
        }
    }

    func approveReviewProposal(_ proposal: WikiReviewProposal) async {
        reviewActionInFlight.insert(proposal.id)
        reviewActionStatus[proposal.id] = "Approving..."
        defer { reviewActionInFlight.remove(proposal.id) }

        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )
        do {
            if reviewMarkdownIsDirty(proposal) {
                reviewActionStatus[proposal.id] = "Saving edits..."
                let saved = try await reviewStore.updateMarkdown(
                    id: proposal.id,
                    proposedMarkdown: currentReviewMarkdown(for: proposal)
                )
                reviewMarkdownDrafts[proposal.id] = saved.proposedMarkdown
                reviewActionStatus[proposal.id] = "Approving..."
            }
            _ = try await reviewStore.approve(id: proposal.id)
            let pageID = "\(proposal.targetSection.rawValue)/\(HarcWikiStore.slug(proposal.targetTitle))"
            if let knowledgeIndexer,
               let page = try? await HarcWikiStore(rootURL: wikiRoot).fetchPage(id: pageID) {
                try await knowledgeIndexer.index(wikiPage: page)
            }
            reviewApprovedPageID[proposal.id] = pageID
            reviewActionStatus[proposal.id] = "Approved and written to Wiki."
            await loadReviewProposals()
            await loadWikiPages()
        } catch {
            reviewActionStatus[proposal.id] = "Approve failed: \(error.localizedDescription)"
        }
    }

    func saveReviewMarkdownDraft(for proposal: WikiReviewProposal) async {
        guard reviewMarkdownIsDirty(proposal) else { return }
        reviewActionInFlight.insert(proposal.id)
        reviewActionStatus[proposal.id] = "Saving edits..."
        defer { reviewActionInFlight.remove(proposal.id) }

        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )
        do {
            let saved = try await reviewStore.updateMarkdown(
                id: proposal.id,
                proposedMarkdown: currentReviewMarkdown(for: proposal)
            )
            reviewMarkdownDrafts[proposal.id] = saved.proposedMarkdown
            reviewActionStatus[proposal.id] = "Edits saved."
            await loadReviewProposals()
        } catch {
            reviewActionStatus[proposal.id] = "Save failed: \(error.localizedDescription)"
        }
    }

    func dismissReviewProposal(_ proposal: WikiReviewProposal) async {
        reviewActionInFlight.insert(proposal.id)
        reviewActionStatus[proposal.id] = "Dismissing..."
        defer { reviewActionInFlight.remove(proposal.id) }

        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )
        do {
            if reviewMarkdownIsDirty(proposal) {
                reviewActionStatus[proposal.id] = "Saving edits..."
                let saved = try await reviewStore.updateMarkdown(
                    id: proposal.id,
                    proposedMarkdown: currentReviewMarkdown(for: proposal)
                )
                reviewMarkdownDrafts[proposal.id] = saved.proposedMarkdown
                reviewActionStatus[proposal.id] = "Dismissing..."
            }
            _ = try await reviewStore.updateStatus(id: proposal.id, status: .dismissed)
            reviewActionStatus[proposal.id] = "Dismissed."
            await loadReviewProposals()
        } catch {
            reviewActionStatus[proposal.id] = "Dismiss failed: \(error.localizedDescription)"
        }
    }

    func loadSelectedNoteDraft() {
        guard let note = selectedNote else { return }
        noteTitleDraft = note.title
        setNoteBodyDraft(note.body)
        noteDirty = false
        noteSaving = false
        noteSavedAt = note.updatedAt
        noteLastLoadedUpdatedAt = note.updatedAt
        noteSaveError = nil
        noteSaveConflict = nil
    }

    func markNoteEdited(advanceGeneration: Bool = true) {
        if advanceGeneration {
            noteDraftSession.generation += 1
        }
        if !noteDirty {
            noteDirty = true
        }
        if noteSaveError != nil {
            noteSaveError = nil
        }
        if noteSaveConflict != nil {
            noteSaveConflict = nil
        }
        scheduleNoteAutosave()
    }

    func scheduleNoteAutosave() {
        noteDraftSession.cancelAutosave()
        guard case .note(let id) = selection else { return }
        let request = NoteSaveRequest(
            id: id,
            title: noteTitleDraft,
            body: currentNoteBodyDraft,
            generation: noteDraftSession.generation,
            baseUpdatedAt: noteLastLoadedUpdatedAt,
            updateDraftIfSelected: true
        )
        noteDraftSession.autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            guard request.generation == noteDraftSession.generation else { return }
            await saveNoteDraft(request)
        }
    }

    func createBlankNote() {
        Task {
            do {
                let note = try await NoteStore(rootURL: prefs.notesURL).create()
                await loadNotes()
                selection = .note(id: note.id)
                noteTitleDraft = note.title
                setNoteBodyDraft(note.body)
                noteDirty = false
                noteSaving = false
                noteSavedAt = note.updatedAt
                noteLastLoadedUpdatedAt = note.updatedAt
                noteSaveError = nil
                noteSaveConflict = nil
            } catch {
                notesError = error.localizedDescription
            }
        }
    }

    func createProject(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let validName = validatedProjectName(name) else {
            newProjectError = "Use a project name without brackets or line breaks."
            return
        }
        let duplicate = inferredProjectNames().contains {
            normalizeWikilinkLabel($0) == normalizeWikilinkLabel(validName)
        }
        guard !duplicate else {
            newProjectError = "That project already exists."
            return
        }

        newProjectSaving = true
        newProjectError = nil
        Task {
            do {
                let saved = try await createProjectSeedNote(named: validName)
                await loadNotes()
                projectsExpanded = true
                selection = .project(name: validName)
                noteTitleDraft = saved.title
                setNoteBodyDraft(saved.body)
                showingNewProject = false
                newProjectName = ""
                newProjectSaving = false
                mutationFailure = nil
                persistNavigationSnapshot()
            } catch {
                newProjectSaving = false
                newProjectError = error.localizedDescription
            }
        }
    }

    func createNote(forProject project: String) {
        guard let validName = validatedProjectName(project) else { return }
        Task {
            do {
                let note = try await createProjectSeedNote(named: validName, titleSuffix: " Note")
                await loadNotes()
                projectsExpanded = true
                selection = .note(id: note.id)
                noteTitleDraft = note.title
                setNoteBodyDraft(note.body)
                noteDirty = false
                mutationFailure = nil
                persistNavigationSnapshot()
            } catch {
                notesError = error.localizedDescription
            }
        }
    }

    func createProjectSeedNote(named project: String, titleSuffix: String = "") async throws -> Note {
        let title = "\(project)\(titleSuffix)"
        let body = """
        # \(project)

        @project[\(project)]

        """
        var note = try await NoteStore(rootURL: prefs.notesURL).create(title: title, body: body)
        note.tags = ["project:\(project)"]
        return try await NoteStore(rootURL: prefs.notesURL).update(note)
    }

    func copyProjectMention(_ project: String) {
        guard let validName = validatedProjectName(project) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("@project[\(validName)]", forType: .string)
    }

    func validatedProjectName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("["),
              !trimmed.contains("]"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r")
        else {
            return nil
        }
        return trimmed
    }

    func archiveNote(_ note: Note) {
        pendingDeleteNote = nil
        noteDraftSession.cancelAutosave()
        Task {
            do {
                try await NoteStore(rootURL: prefs.notesURL).archive(id: note.id)
                try? await store.deleteKnowledgeChunks(sourceKind: .note, sourceID: note.id)
                if selection == .note(id: note.id) {
                    selection = nil
                    noteTitleDraft = ""
                    setNoteBodyDraft("")
                    noteDirty = false
                    noteSaveError = nil
                    noteSaveConflict = nil
                    noteSavedAt = nil
                    noteLastLoadedUpdatedAt = nil
                }
                await loadNotes()
                mutationFailure = nil
            } catch {
                notesError = error.localizedDescription
                reportMutationFailure(.archiveNote(note.title), error: error)
            }
        }
    }

    func toggleNotePin(_ note: Note) {
        Task {
            do {
                try await NoteStore(rootURL: prefs.notesURL).setPinned(id: note.id, pinned: !note.pinned)
                await loadNotes(resetDraft: false)
                mutationFailure = nil
            } catch {
                notesError = error.localizedDescription
                reportMutationFailure(.pinNote(note.title), error: error)
            }
        }
    }

    func saveSelectedNote() {
        guard case .note(let id) = selection else { return }
        noteDraftSession.cancelAutosave()
        let request = NoteSaveRequest(
            id: id,
            title: noteTitleDraft,
            body: currentNoteBodyDraft,
            generation: noteDraftSession.generation,
            baseUpdatedAt: noteLastLoadedUpdatedAt,
            updateDraftIfSelected: true
        )
        Task {
            await saveNoteDraft(request)
        }
    }

    func flushOutgoingNoteIfNeeded(_ oldSelection: LibrarySelection?) {
        guard case .note(let id) = oldSelection, noteDirty else { return }
        noteDraftSession.cancelAutosave()
        let request = NoteSaveRequest(
            id: id,
            title: noteTitleDraft,
            body: currentNoteBodyDraft,
            generation: noteDraftSession.generation,
            baseUpdatedAt: noteLastLoadedUpdatedAt,
            updateDraftIfSelected: false
        )
        Task {
            await saveNoteDraft(request)
        }
    }

    func saveNoteDraft(_ request: NoteSaveRequest, allowOverwrite: Bool = false) async {
        guard var note = notes.first(where: { $0.id == request.id }) else { return }
        let noteStore = NoteStore(rootURL: prefs.notesURL)
        let diskNote = try? await noteStore.fetch(id: request.id, includeArchived: true)
        switch NoteAutosaveGuard.shouldSave(
            request: request,
            currentGeneration: noteDraftSession.generation,
            selectedNoteID: selectedNoteID,
            diskNote: diskNote,
            allowOverwrite: allowOverwrite
        ) {
        case .save:
            break
        case .stale:
            return
        case .conflict(let conflict):
            if selection == .note(id: request.id) {
                noteSaveConflict = conflict
                noteSaveError = "This note changed on disk. Reload it or overwrite the file with your draft."
                noteSaving = false
            } else {
                notesError = "Could not autosave note because it changed on disk."
            }
            return
        }

        note.title = request.title
        note.body = request.body
        noteSaving = true
        do {
            note.people = try await ensureMentionedPeople(in: request.body)
            note.tags = mergedProjectTags(existing: note.tags, body: request.body)
            let saved = try await noteStore.update(note)
            if let knowledgeIndexer {
                Task.detached { [knowledgeIndexer, saved] in
                    try? await knowledgeIndexer.index(note: saved)
                }
            }
            await loadNotes(resetDraft: false)
            if request.updateDraftIfSelected,
               selection == .note(id: request.id),
               request.generation == noteDraftSession.generation || allowOverwrite {
                noteTitleDraft = saved.title
                setNoteBodyDraft(saved.body)
                noteDirty = false
                noteSavedAt = saved.updatedAt
                noteLastLoadedUpdatedAt = saved.updatedAt
                noteSaveError = nil
                noteSaveConflict = nil
            }
            if selection != .note(id: request.id) {
                noteSaveError = nil
            }
        } catch {
            if selection == .note(id: request.id) {
                noteSaveError = error.localizedDescription
            } else {
                notesError = "Could not autosave note: \(error.localizedDescription)"
            }
        }
        noteSaving = false
    }

    var selectedNoteID: String? {
        if case .note(let id) = selection { return id }
        return nil
    }

    func reloadConflictedNote(_ conflict: NoteSaveConflict) {
        Task {
            do {
                guard let note = try await NoteStore(rootURL: prefs.notesURL).fetch(id: conflict.noteID, includeArchived: true) else {
                    noteSaveError = "Could not reload the note from disk."
                    return
                }
                if selection == .note(id: conflict.noteID) {
                    noteTitleDraft = note.title
                    setNoteBodyDraft(note.body)
                    noteDirty = false
                    noteSaving = false
                    noteSavedAt = note.updatedAt
                    noteLastLoadedUpdatedAt = note.updatedAt
                    noteSaveError = nil
                    noteSaveConflict = nil
                }
                await loadNotes(resetDraft: false)
            } catch {
                noteSaveError = error.localizedDescription
            }
        }
    }

    @MainActor
    func pasteImage(_ image: NotePastedImage, into noteID: String) async throws -> String {
        let noteStore = NoteStore(rootURL: prefs.notesURL)
        let result = try await noteStore.attachImage(
            toNoteID: noteID,
            data: image.data,
            mimeType: image.mimeType,
            preferredFilename: image.filename
        )
        let shouldCaption = ModelCatalog.descriptors(for: .visionCaptioner)
            .first
            .map { modelStore.state(of: $0.id).isInstalled } ?? false
        var note = result.note
        let baseBody = selection == .note(id: noteID) ? currentNoteBodyDraft : note.body
        note.body = Self.appendingImageBlock(
            to: baseBody,
            attachment: result.attachment,
            caption: shouldCaption ? "Caption pending..." : nil
        )
        let saved = try await noteStore.update(note)

        if selection == .note(id: noteID) {
            setNoteBodyDraft(saved.body)
            noteSavedAt = saved.updatedAt
            noteLastLoadedUpdatedAt = saved.updatedAt
            noteDirty = false
            noteSaveError = nil
        }
        await loadNotes(resetDraft: false)
        startCaptionIfAvailable(noteID: noteID, attachmentID: result.attachment.id)
        return ""
    }

    func attachmentStatusText(for note: Note) -> String {
        let count = note.attachments.count
        let captioned = note.attachments.filter { $0.captionStatus == .captioned }.count
        if captioned > 0 {
            return "\(count) image\(count == 1 ? "" : "s"), \(captioned) captioned"
        }
        return "\(count) image\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    func noteAttachmentsStrip(note: Note) -> some View {
        if !note.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(note.attachments) { attachment in
                        Menu {
                            Button {
                                revealAttachment(attachment, in: note)
                            } label: {
                                Label("Reveal File", systemImage: "folder")
                            }
                            Button {
                                copyAttachmentImage(attachment, in: note)
                            } label: {
                                Label("Copy Image", systemImage: "doc.on.doc")
                            }
                            Button {
                                startCaption(noteID: note.id, attachmentID: attachment.id)
                            } label: {
                                Label("Regenerate Caption", systemImage: "sparkles")
                            }
                            Divider()
                            Button(role: .destructive) {
                                removeAttachment(attachment, from: note)
                            } label: {
                                Label("Remove Image", systemImage: "trash")
                            }
                        } label: {
                            Label(attachmentMenuTitle(attachment), systemImage: attachmentIconName(attachment))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .menuStyle(.button)
                        .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func attachmentMenuTitle(_ attachment: NoteAttachment) -> String {
        if captioningAttachmentIDs.contains(attachment.id) {
            return "Captioning..."
        }
        switch attachment.captionStatus {
        case .captioned:
            return attachment.altText
        case .failed:
            return "Caption failed"
        case .pending:
            return "Caption pending"
        case .unavailable:
            return attachment.altText
        }
    }

    func attachmentIconName(_ attachment: NoteAttachment) -> String {
        if captioningAttachmentIDs.contains(attachment.id) { return "sparkles" }
        switch attachment.captionStatus {
        case .captioned: return "photo.badge.checkmark"
        case .failed: return "photo.badge.exclamationmark"
        case .pending: return "sparkles"
        case .unavailable: return "photo"
        }
    }

    func attachmentURL(_ attachment: NoteAttachment, in note: Note) -> URL {
        note.fileURL.deletingLastPathComponent().appendingPathComponent(attachment.relativePath)
    }

    func revealAttachment(_ attachment: NoteAttachment, in note: Note) {
        NSWorkspace.shared.activateFileViewerSelecting([attachmentURL(attachment, in: note)])
    }

    func copyAttachmentImage(_ attachment: NoteAttachment, in note: Note) {
        guard let image = NSImage(contentsOf: attachmentURL(attachment, in: note)) else {
            noteSaveError = "Could not load image for copying."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func removeAttachment(_ attachment: NoteAttachment, from note: Note) {
        Task {
            do {
                let saved = try await NoteStore(rootURL: prefs.notesURL).removeAttachment(
                    noteID: note.id,
                    attachmentID: attachment.id
                )
                await loadNotes(resetDraft: false)
                if selection == .note(id: note.id) {
                    setNoteBodyDraft(saved.body)
                    noteSavedAt = saved.updatedAt
                    noteLastLoadedUpdatedAt = saved.updatedAt
                    noteDirty = false
                }
            } catch {
                noteSaveError = error.localizedDescription
            }
        }
    }

    func startCaptionIfAvailable(noteID: String, attachmentID: String) {
        let captionerID = ModelCatalog.descriptors(for: .visionCaptioner).first?.id
        guard let captionerID, modelStore.state(of: captionerID).isInstalled else { return }
        startCaption(noteID: noteID, attachmentID: attachmentID)
    }

    func startCaption(noteID: String, attachmentID: String) {
        Task {
            let noteStore = NoteStore(rootURL: prefs.notesURL)
            let captionerID = ModelCatalog.descriptors(for: .visionCaptioner).first?.id
            guard let captionerID else { return }
            guard modelStore.state(of: captionerID).isInstalled else {
                noteSaveError = "Image caption model is not installed."
                _ = try? await noteStore.updateAttachmentCaption(
                    noteID: noteID,
                    attachmentID: attachmentID,
                    caption: nil,
                    status: .unavailable
                )
                await loadNotes(resetDraft: false)
                return
            }
            captioningAttachmentIDs.insert(attachmentID)
            defer { captioningAttachmentIDs.remove(attachmentID) }
            do {
                let pending = try await noteStore.updateAttachmentCaption(
                    noteID: noteID,
                    attachmentID: attachmentID,
                    caption: nil,
                    status: .pending,
                    modelID: captionerID
                )
                await loadNotes(resetDraft: false)
                guard let attachment = pending.attachments.first(where: { $0.id == attachmentID }) else {
                    throw StoreError.notFound
                }
                let modelDirectory = try await modelStore.manager.requireInstalled(captionerID)
                let imageURL = attachmentURL(attachment, in: pending)
                let caption = try await VisionCaptionService().caption(VisionCaptionRequest(
                    imageURL: imageURL,
                    modelID: captionerID,
                    modelDirectory: modelDirectory
                ))
                let saved = try await noteStore.updateAttachmentCaption(
                    noteID: noteID,
                    attachmentID: attachmentID,
                    caption: caption,
                    status: .captioned,
                    modelID: captionerID
                )
                var noteWithVisibleCaption = saved
                let bodyBase = selection == .note(id: noteID) ? currentNoteBodyDraft : saved.body
                noteWithVisibleCaption.body = Self.replacingImageCaption(
                    in: bodyBase,
                    attachment: attachment,
                    caption: caption
                )
                let visibleCaptionSaved = try await noteStore.update(noteWithVisibleCaption)
                if selection == .note(id: noteID) {
                    setNoteBodyDraft(visibleCaptionSaved.body)
                    noteSavedAt = visibleCaptionSaved.updatedAt
                    noteLastLoadedUpdatedAt = visibleCaptionSaved.updatedAt
                    noteDirty = false
                }
                if let knowledgeIndexer {
                    Task.detached { [knowledgeIndexer, visibleCaptionSaved] in
                        try? await knowledgeIndexer.index(note: visibleCaptionSaved)
                    }
                }
                await loadNotes(resetDraft: false)
            } catch {
                _ = try? await noteStore.updateAttachmentCaption(
                    noteID: noteID,
                    attachmentID: attachmentID,
                    caption: error.localizedDescription,
                    status: .failed,
                    modelID: captionerID
                )
                noteSaveError = error.localizedDescription
                await loadNotes(resetDraft: false)
            }
        }
    }

    static func imageMarkdownReference(for attachment: NoteAttachment) -> String {
        "![\(markdownEscapedAltText(attachment.altText))](./\(attachment.relativePath))"
    }

    static func appendingImageBlock(
        to body: String,
        attachment: NoteAttachment,
        caption: String?
    ) -> String {
        let block = imageMarkdownBlock(for: attachment, caption: caption)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return block }
        return "\(trimmed)\n\n\(block)"
    }

    static func replacingImageCaption(
        in body: String,
        attachment: NoteAttachment,
        caption: String
    ) -> String {
        let reference = imageMarkdownReference(for: attachment)
        var lines = body.components(separatedBy: .newlines)
        guard let imageIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == reference }) else {
            return appendingImageBlock(to: body, attachment: attachment, caption: caption)
        }

        var captionIndex = imageIndex + 1
        if captionIndex < lines.count, lines[captionIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            captionIndex += 1
        }

        let nextLine = captionIndex < lines.count
            ? lines[captionIndex].trimmingCharacters(in: .whitespaces)
            : ""
        let captionLine = markdownCaptionLine(caption)
        if nextLine.hasPrefix("*Caption") && nextLine.hasSuffix("*") {
            lines[captionIndex] = captionLine
        } else {
            lines.insert(contentsOf: ["", captionLine], at: imageIndex + 1)
        }
        return lines.joined(separator: "\n")
    }

    static func imageMarkdownBlock(for attachment: NoteAttachment, caption: String?) -> String {
        guard let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return imageMarkdownReference(for: attachment)
        }
        return "\(imageMarkdownReference(for: attachment))\n\n\(markdownCaptionLine(caption))"
    }

    static func markdownCaptionLine(_ caption: String) -> String {
        "*Caption: \(markdownInlineText(caption))*"
    }

    static func markdownEscapedAltText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    static func markdownInlineText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "*", with: "\\*")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func overwriteConflictedNote(_ conflict: NoteSaveConflict) {
        noteSaveConflict = nil
        noteSaveError = nil
        let request = NoteSaveRequest(
            id: conflict.noteID,
            title: conflict.draftTitle,
            body: conflict.draftBody,
            generation: noteDraftSession.generation,
            baseUpdatedAt: nil,
            updateDraftIfSelected: true
        )
        Task {
            await saveNoteDraft(request, allowOverwrite: true)
        }
    }

    func reportMutationFailure(_ action: LibraryMutationAction, error: Error) {
        mutationFailure = LibraryMutationFailure(action: action, error: error)
    }

    func noteMentionTargets() -> [NoteMarkdownLinkTarget] {
        let people = deduplicatedMentionPeople(
            peopleVM.people.map(\.person) + allPeople + noteMentionPeople
        )
        let personTargets = people.map {
            NoteMarkdownLinkTarget(
                label: $0.displayName,
                kind: "person",
                detail: "Person"
            )
        }
        let projectTargets = inferredProjectNames().map {
            NoteMarkdownLinkTarget(
                label: $0,
                kind: "project",
                detail: "Project"
            )
        }
        return deduplicatedLinkTargets(personTargets + projectTargets)
    }

    func loadNoteMentionPeople() async {
        noteMentionPeople = (try? await store.fetchPeople()) ?? []
    }

    func ensureMentionedPeople(in body: String) async throws -> [String] {
        var people = try await store.fetchPeople()
        var ids: [String] = []
        var seenIDs: Set<Int64> = []
        var unresolved: [String] = []

        for action in NotePersonMentionResolver.actions(for: body, people: people) {
            switch action {
            case .link(let personID):
                if seenIDs.insert(personID).inserted {
                    ids.append("person:\(personID)")
                }
            case .create(let name):
                let personID = try await store.createPerson(displayName: name, matchThreshold: nil)
                let now = Date()
                let person = Person(
                    id: personID,
                    displayName: name,
                    matchThreshold: nil,
                    createdAt: now,
                    updatedAt: now
                )
                people.append(person)
                noteMentionPeople.append(person)
                if seenIDs.insert(personID).inserted {
                    ids.append("person:\(personID)")
                }
            case .unresolvedBare(let name):
                unresolved.append(name)
            }
        }

        unresolvedBarePersonMentions = unresolved
        return ids
    }

    func noteLinkTargets(for currentNote: Note) -> [NoteMarkdownLinkTarget] {
        let noteTargets = notes
            .filter { $0.id != currentNote.id }
            .map {
                NoteMarkdownLinkTarget(
                    label: $0.title,
                    kind: "note",
                    detail: "Note"
                )
            }
        let recordingTargets = libraryVM.recordings.map {
            NoteMarkdownLinkTarget(
                label: $0.displayTitle,
                kind: "recording",
                detail: formatRecordingLinkDetail($0)
            )
        }
        return deduplicatedLinkTargets(noteTargets + recordingTargets)
    }

    func resolvedWikilinks(in body: String, currentNoteID: String) -> [ResolvedWikilink] {
        extractWikilinkLabels(from: body).map { label in
            let normalized = normalizeWikilinkLabel(label)
            if let note = notes.first(where: {
                $0.id != currentNoteID && normalizeWikilinkLabel($0.title) == normalized
            }) {
                return ResolvedWikilink(
                    id: "note:\(note.id):\(label)",
                    title: note.title,
                    target: .note(id: note.id)
                )
            }
            if let recording = libraryVM.recordings.first(where: {
                normalizeWikilinkLabel($0.displayTitle) == normalized
            }) {
                return ResolvedWikilink(
                    id: "recording:\(recording.wavPath):\(label)",
                    title: recording.displayTitle,
                    target: .recording(wavPath: recording.wavPath)
                )
            }
            return ResolvedWikilink(
                id: "unresolved:\(label)",
                title: label,
                target: .unresolved
            )
        }
    }

    func openWikilink(_ link: ResolvedWikilink) {
        switch link.target {
        case .note(let id):
            selection = .note(id: id)
        case .recording(let wavPath):
            selection = .recording(wavPath: wavPath)
        case .unresolved:
            break
        }
    }

    func extractWikilinkLabels(from body: String) -> [String] {
        let pattern = #"\[\[([^\]\n]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen: Set<String> = []
        return regex.matches(in: body, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: body) else {
                return nil
            }
            let label = String(body[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeWikilinkLabel(label)
            guard !label.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return label
        }
    }

    func extractProjectMentions(from body: String) -> [ProjectMention] {
        let pattern = #"@project\[([^\]\n]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var seen: Set<String> = []

        return regex.matches(in: body, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: body) else {
                return nil
            }
            let name = String(body[swiftRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeWikilinkLabel(name)
            guard !name.isEmpty, !seen.contains(key) else { return nil }
            seen.insert(key)
            return ProjectMention(name: name)
        }
    }

    func mergedProjectTags(existing tags: [String], body: String) -> [String] {
        var result = tags.filter { !$0.lowercased().hasPrefix("project:") }
        var seen = Set(result.map(normalizeWikilinkLabel))

        for mention in extractProjectMentions(from: body) {
            let tag = "project:\(mention.name)"
            let key = normalizeWikilinkLabel(tag)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(tag)
        }

        return result
    }

    func inferredProjectNames() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        func append(_ rawName: String) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeWikilinkLabel(name)
            guard !name.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            result.append(name)
        }

        for note in notes {
            for tag in note.tags {
                guard tag.lowercased().hasPrefix("project:") else { continue }
                append(String(tag.dropFirst("project:".count)))
            }
            for mention in extractProjectMentions(from: note.body) {
                append(mention.name)
            }
        }
        for recording in libraryVM.recordings {
            for tag in recording.tags {
                guard tag.lowercased().hasPrefix("project:") else { continue }
                append(String(tag.dropFirst("project:".count)))
            }
        }

        return result.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func projectCounts(for project: String) -> (notes: Int, recordings: Int) {
        (notesForProject(project).count, recordingsForProject(project).count)
    }

    func notesForProject(_ project: String) -> [Note] {
        let key = normalizeWikilinkLabel(project)
        return notes.filter { note in
            note.tags.contains { tag in
                tag.lowercased().hasPrefix("project:") &&
                    normalizeWikilinkLabel(String(tag.dropFirst("project:".count))) == key
            } || extractProjectMentions(from: note.body).contains {
                normalizeWikilinkLabel($0.name) == key
            }
        }
    }

    func recordingsForProject(_ project: String) -> [Recording] {
        let key = normalizeWikilinkLabel(project)
        let linkedRecordingIDs = Set(notesForProject(project).flatMap(\.recordings))
        return libraryVM.recordings.filter { recording in
            if recording.tags.contains(where: { tag in
                tag.lowercased().hasPrefix("project:") &&
                    normalizeWikilinkLabel(String(tag.dropFirst("project:".count))) == key
            }) {
                return true
            }
            if let id = recording.id, linkedRecordingIDs.contains("recording:\(id)") {
                return true
            }
            return linkedRecordingIDs.contains("recording-path:\(recording.wavPath)")
        }
    }

    func normalizeWikilinkLabel(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    func deduplicatedLinkTargets(_ targets: [NoteMarkdownLinkTarget]) -> [NoteMarkdownLinkTarget] {
        var seen: Set<String> = []
        var result: [NoteMarkdownLinkTarget] = []
        for target in targets {
            let key = "\(target.kind):\(normalizeWikilinkLabel(target.label))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(target)
        }
        return result
    }

    func deduplicatedMentionPeople(_ people: [Person]) -> [Person] {
        var seenIDs: Set<Int64> = []
        var seenNames: Set<String> = []
        var result: [Person] = []

        for person in people.sorted(by: {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }) {
            let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let normalized = normalizeWikilinkLabel(name)
            guard !seenIDs.contains(person.id), !seenNames.contains(normalized) else { continue }
            seenIDs.insert(person.id)
            seenNames.insert(normalized)
            result.append(person)
        }

        return result
    }

    func formatRecordingLinkDetail(_ recording: Recording) -> String {
        if let endedAt = recording.endedAt {
            return "Recording · \(Self.formatDuration(from: recording.startedAt, to: endedAt))"
        }
        return "Recording"
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
    func copyTranscript(_ recording: Recording) {
        let text = transcriptText.isEmpty ? (recording.transcriptText ?? "") : transcriptText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copySearchContext() {
        let query = libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            contextCopyStatus = "Enter a search query first."
            return
        }

        contextCopyInFlight = true
        contextCopyStatus = "Building local context..."
        Task {
            do {
                let markdown = try await scopedContextMarkdown(for: query)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    contextCopyStatus = "Copied Markdown context."
                    contextCopyInFlight = false
                }
            } catch {
                await MainActor.run {
                    contextCopyStatus = "Could not build context."
                    contextCopyInFlight = false
                }
            }
        }
    }

    func answerSearchContext() {
        let query = libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            conversationStatus = "Enter a question first."
            return
        }
        guard modelStore.state(of: prefs.activeSummarizerID).isInstalled else {
            conversationStatus = "Install the active local model in Settings first."
            return
        }

        conversationInFlight = true
        conversationAnswer = nil
        conversationStatus = "Building local context..."
        let modelID = prefs.activeSummarizerID
        let modelDirectory = ModelStorage.defaultBase()
            .appendingPathComponent(modelID, isDirectory: true)
        Task {
            do {
                let context = try await scopedContextMarkdown(for: query)
                await MainActor.run {
                    conversationStatus = "Answering with \(ModelCatalog.descriptor(for: modelID)?.displayName ?? modelID)..."
                }
                let answer = try await summarizerService.answer(
                    question: query,
                    contextMarkdown: context,
                    modelID: modelID,
                    modelDirectory: modelDirectory
                )
                await MainActor.run {
                    conversationAnswer = answer.isEmpty ? "No answer generated." : answer
                    conversationStatus = "Answered locally."
                    conversationInFlight = false
                }
            } catch {
                await MainActor.run {
                    conversationStatus = "Could not answer locally: \(error.localizedDescription)"
                    conversationInFlight = false
                }
            }
        }
    }

    func scopedContextMarkdown(for query: String) async throws -> String {
        switch contextPackScope {
        case .topResults:
            return try await libraryVM.contextMarkdown(
                for: query,
                limit: 8,
                noteStore: NoteStore(rootURL: prefs.notesURL)
            )
        case .visibleResults:
            return try await libraryVM.contextMarkdown(
                for: query,
                limit: max(1, max(libraryVM.hits.count, noteSearchResults.count)),
                noteStore: NoteStore(rootURL: prefs.notesURL)
            )
        case .selectedResult:
            if let note = selectedNote {
                return selectedNoteContextMarkdown(note, query: query)
            }
            if let recording = selectedRecording {
                return selectedRecordingContextMarkdown(recording, query: query)
            }
            throw ContextScopeError.noSelectedSource
        }
    }

    func selectedNoteContextMarkdown(_ note: Note, query: String) -> String {
        """
        # Context: \(query)

        Scope: Selected note

        ## Relevant Evidence

        ### \(note.title)
        \(note.body)
        \(noteAttachmentContext(note))

        ## Sources
        - Note: \(note.title) - \(note.fileURL.path)
        """
    }

    func noteAttachmentContext(_ note: Note) -> String {
        let lines = note.attachments.compactMap { attachment -> String? in
            let text = attachment.searchableText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "- Image: \(text)"
        }
        guard !lines.isEmpty else { return "" }
        return "\n\n### Images\n" + lines.joined(separator: "\n")
    }

    func selectedRecordingContextMarkdown(_ recording: Recording, query: String) -> String {
        var sections: [String] = [
            "# Context: \(query)",
            "",
            "Scope: Selected recording",
            "",
            "## Relevant Evidence",
            "",
            "### \(recording.displayTitle)",
            recording.transcriptText?.harcTrimmedNonEmpty ?? transcriptText.harcTrimmedNonEmpty ?? "_No transcript text available._",
        ]
        if let summary = recording.summaryMarkdown?.harcTrimmedNonEmpty {
            sections += ["", "## Summaries", "", "### \(recording.displayTitle)", summary]
        }
        if let actions = recording.actionItemsMarkdown?.harcTrimmedNonEmpty {
            sections += ["", "## Action Items", "", "### \(recording.displayTitle)", actions]
        }
        sections += ["", "## Sources", "- Recording: \(recording.displayTitle) - \(recording.wavPath)"]
        return sections.joined(separator: "\n")
    }

    /// True when there is any transcript source available for this recording.
    func hasTranscriptSource(_ rec: Recording) -> Bool {
        if let text = rec.transcriptText, !text.isEmpty { return true }
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
        guard let recording = selectedRecording else { return }

        // Plain text for fallback / pasteboard copy.
        if let cached = recording.transcriptText, !cached.isEmpty {
            transcriptText = cached
        } else if let txtPath = recording.txtPath {
            do {
                transcriptText = try String(contentsOf: URL(fileURLWithPath: txtPath), encoding: .utf8)
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

