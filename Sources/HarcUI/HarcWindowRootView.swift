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

// MARK: - LibrarySelection

/// Discriminated union for the sidebar selection. Either a recording (keyed
/// by wav path) or a Person row (keyed by DB id). Phase 6 wires the
/// person-detail pane; for now selecting a Person leaves the detail pane
/// in its empty state.
public enum LibrarySelection: Hashable {
    case note(id: String)
    case recording(wavPath: String)
    case person(id: Int64)
    case project(name: String)
}

private enum HarcLibraryMode: String, CaseIterable, Identifiable {
    case library = "Library"
    case wiki = "Wiki"
    case review = "Review"

    var id: String { rawValue }
}

private enum ContextPackScope: String, CaseIterable, Identifiable {
    case topResults = "Top"
    case visibleResults = "Visible"
    case selectedResult = "Selected"

    var id: String { rawValue }
}

private enum ContextScopeError: LocalizedError {
    case noSelectedSource

    var errorDescription: String? {
        "Select a note or recording before using Selected scope."
    }
}

private struct ResolvedWikilink: Identifiable {
    enum Target {
        case note(id: String)
        case recording(wavPath: String)
        case unresolved
    }

    let id: String
    let title: String
    let target: Target

    var isResolved: Bool {
        if case .unresolved = target { return false }
        return true
    }

    var iconName: String {
        switch target {
        case .note: return "note.text"
        case .recording: return "waveform"
        case .unresolved: return "questionmark.circle"
        }
    }

    var helpText: String {
        switch target {
        case .note: return "Open linked note"
        case .recording: return "Open linked recording"
        case .unresolved: return "No matching note or recording"
        }
    }
}

private struct ProjectMention {
    let name: String
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
    let knowledgeIndexer: KnowledgeIndexer?
    let onEdit: (Recording) -> Void
    let onDelete: (Recording) -> Void

    // MARK: View state

    /// Primary selection — `.recording(wavPath:)` for recordings, `.person(id:)` for People.
    @State private var selection: LibrarySelection?
    @State private var mode: HarcLibraryMode = .library
    @State private var wikiSection: WikiSection = .overview
    @State private var selectedWikiPageID: String?
    @State private var wikiPages: [WikiPage] = []
    @State private var wikiLoadError: String?
    @State private var reviewProposals: [WikiReviewProposal] = []
    @State private var selectedReviewProposalID: String?
    @State private var reviewLoadError: String?
    @State private var reviewActionInFlight: Set<String> = []
    @State private var reviewActionStatus: [String: String] = [:]
    @State private var reviewApprovedPageID: [String: String] = [:]
    @State private var sourceScanStatus: String?
    @State private var mutationFailure: LibraryMutationFailure?
    @State private var inspectorOpen: Bool = false
    @State private var showingAddPerson = false

    // Transcript text is loaded lazily on selection change to avoid
    // synchronous disk I/O in the view body.
    @State private var transcriptText: String = ""
    /// Set when the user picks Delete from a sidebar context menu — drives
    /// the destructive confirmation alert.
    @State private var pendingDeleteRecording: Recording? = nil
    @State private var pendingDeleteNote: Note? = nil
    /// When the .json sidecar is available, we render structured turns
    /// (timestamp + speaker + text) instead of the flat .txt blob.
    @State private var transcriptSegments: [TranscriptDisplaySegment] = []
    @State private var transcriptLoadError: String? = nil
    @State private var transcriptFindVisible = false
    @State private var transcriptSearchText = ""
    @State private var transcriptSearchIndex = 0
    @FocusState private var transcriptSearchFocused: Bool
    @State private var detailEnvelope: [Float] = []
    /// Resolved speaker labels for the current selection, keyed by speaker
    /// index. Populated asynchronously on selection change via
    /// `loadResolvedLabels()` so Person-linked names show up in transcript
    /// turns. Falls back to the raw `recordings.speaker_names` JSON or
    /// "Speaker N+1" when no Person link exists (same resolution order as
    /// `RecordingStore.resolvedSpeakerName`).
    @State private var resolvedSpeakerLabels: [Int: String] = [:]

    // Task 8.1: pending suggestions for the inspector chip system
    @State private var inspectorPendingSuggestions: [PendingSuggestion] = []
    // Task 8.1/8.2: Person name lookup and full list for the picker
    @State private var allPeopleByID: [Int64: String] = [:]
    @State private var allPeople: [Person] = []
    @State private var contextCopyStatus: String?
    @State private var contextCopyInFlight = false
    @State private var contextPackScope: ContextPackScope = .topResults
    @State private var conversationAnswer: String?
    @State private var conversationStatus: String?
    @State private var conversationInFlight = false
    @State private var notes: [Note] = []
    @State private var didLoadNotes = false
    @State private var noteSearchResults: [Note] = []
    @State private var notesError: String?
    @State private var noteTitleDraft: String = ""
    @State private var noteBodyDraft: String = ""
    @State private var noteDirty: Bool = false
    @State private var noteSaving: Bool = false
    @State private var noteSavedAt: Date?
    @State private var noteSaveGeneration = 0
    @State private var noteLastLoadedUpdatedAt: Date?
    @State private var noteAutosaveTask: Task<Void, Never>?
    @State private var noteSaveError: String?
    @State private var noteSaveConflict: NoteSaveConflict?
    @State private var captioningAttachmentIDs: Set<String> = []
    @State private var unresolvedBarePersonMentions: [String] = []
    @State private var noteEditorMode: NoteMarkdownEditorMode = .live
    @State private var noteMentionPeople: [Person] = []
    @State private var linkedNotes: [Note] = []
    @State private var linkedNotesError: String?
    @State private var notesExpanded = true
    @State private var expandedNoteBuckets: Set<String> = []
    @State private var knownNoteBucketIDs: Set<String> = []
    @State private var projectsExpanded = false
    @State private var peopleExpanded = false
    @State private var recordingsExpanded = true
    @State private var restoredSelection: LibrarySelection?
    @State private var exportRecording: Recording?
    @State private var exportDraft = RecordingExportDraft(includeSummary: true)

    // MARK: Environment

    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var postProcessing: RecordingPostProcessingState
    @EnvironmentObject private var modelStore: ModelManagerStore

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

    private var modeSwitcher: some View {
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

    private var pendingDeleteRecordingBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteRecording != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteRecording = nil }
            }
        )
    }

    private var pendingDeleteNoteBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteNote != nil },
            set: { isPresented in
                if !isPresented { pendingDeleteNote = nil }
            }
        )
    }

    private var noteIDsForNavigation: [String] {
        notes.map(\.id)
    }

    private var recordingPathsForNavigation: [String] {
        libraryVM.recordings.map(\.wavPath)
    }

    private var personIDsForNavigation: [Int64] {
        peopleVM.people.map { $0.person.id }
    }

    private var navigationValidationToken: String {
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
        .sheet(item: $exportRecording) { recording in
            RecordingExportSheet(
                recording: recording,
                draft: $exportDraft,
                onCancel: { exportRecording = nil },
                onExported: { exportRecording = nil }
            )
        }
    }

    private func handleAppear() {
        restoreNavigationSnapshot()
        libraryVM.start()
        peopleVM.start()
        Task {
            await loadInitialData()
        }
    }

    private func handleDisappear() {
        noteAutosaveTask?.cancel()
        libraryVM.stop()
        peopleVM.stop()
    }

    private func loadInitialData() async {
        await loadNotes()
        await loadNoteMentionPeople()
        await loadWikiPages()
        await loadReviewProposals()
    }

    @ViewBuilder
    private var split: some View {
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

    private var inspectorToolbarTitle: String {
        let count = inspectorAttentionCount
        return count > 0 ? "Inspector (\(count))" : "Inspector"
    }

    private var inspectorAttentionCount: Int {
        inspectorPendingSuggestions.count + linkedNotes.count
    }

    // MARK: - Library footer (status bar)

    private var libraryFooter: some View {
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

    private var footerStackHardware: some View {
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

    private var footerCountAndStorage: String {
        let isSearching = !libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let count = isSearching ? libraryVM.hits.count : libraryVM.recordings.count
        let label = count == 1 ? "recording" : "recordings"
        return "\(count) \(label) · \(footerStorageString)"
    }

    private var footerStorageString: String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: libraryVM.totalBytes)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
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

    private var wikiSidebar: some View {
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

    private var reviewSidebar: some View {
        List(selection: $selectedReviewProposalID) {
            Section("Queue") {
                reviewBucket("Pending", statuses: [.pending, .edited])
                reviewBucket("Approved", statuses: [.approved])
                reviewBucket("Dismissed", statuses: [.dismissed, .failed])
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Calendar header

    private var calendarHeader: some View {
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

    private var contextScopeDescription: String {
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

    private var selectedFilterDay: Date? {
        if case .day(let d) = libraryVM.filter { return d }
        return nil
    }

    private func daysWithNotes(inMonthContaining month: Date) -> Set<Date> {
        NoteCalendarIndex.daysWithNotes(notes, inMonthContaining: month)
    }

    private func formatFilterDay(_ day: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: day)
    }

    // Grouped library list: capture work stays first; organization surfaces
    // remain available without competing with the common record-review loop.
    private var groupedList: some View {
        List(selection: $selection) {
            Section {
                captureSidebarActions
            }

            DisclosureGroup(isExpanded: persistedExpansionBinding(.recordings)) {
                recordingSidebarList
            } label: {
                Label("Recent Recordings", systemImage: "waveform")
            }

            DisclosureGroup(isExpanded: persistedExpansionBinding(.notes)) {
                noteSidebarList
            } label: {
                Label("Active Notes", systemImage: "note.text")
            }

            Section("Organize") {
                DisclosureGroup(isExpanded: persistedExpansionBinding(.projects)) {
                    projectSidebarList
                } label: {
                    Label("Projects", systemImage: "folder")
                }

                DisclosureGroup(isExpanded: persistedExpansionBinding(.people)) {
                    peopleSidebarList
                } label: {
                    Label("People", systemImage: "person.2")
                }
            }
        }
    }

    private var captureSidebarActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                bridge.onStartStop()
            } label: {
                Label(recordingState.isRecording ? "Stop Recording" : "Record", systemImage: recordingState.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("harc.library.capture.recordButton")
            Text("Use the menu bar icon or configure the global hotkey in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
                .font(.caption)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var recordingSidebarList: some View {
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
    private var projectSidebarList: some View {
        let projects = inferredProjectNames()
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
    private var peopleSidebarList: some View {
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

    private enum SidebarExpansionGroup {
        case notes
        case projects
        case people
        case recordings
    }

    private func persistedExpansionBinding(_ group: SidebarExpansionGroup) -> Binding<Bool> {
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
    private var noteSidebarList: some View {
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

    private func noteBucketLabel(_ title: String, count: Int) -> some View {
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

    private func noteBucketBinding(_ id: String) -> Binding<Bool> {
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

    private func seedDefaultNoteBucketExpansion() {
        let grouping = NoteSidebarGrouping.make(notes: notes, selectedDay: selectedFilterDay)
        var currentIDs = Set(grouping.buckets.map(\.id))
        if !grouping.pinned.isEmpty { currentIDs.insert("pinned") }
        if !grouping.recent.isEmpty { currentIDs.insert("recent") }
        let newIDs = currentIDs.subtracting(knownNoteBucketIDs)
        expandedNoteBuckets.formUnion(grouping.defaultExpandedBucketIDs.intersection(newIDs))
        knownNoteBucketIDs.formUnion(currentIDs)
        expandedNoteBuckets.formIntersection(currentIDs)
    }

    private func restoreNavigationSnapshot() {
        let snapshot = LibraryNavigationStateStore.load()
        if let restoredMode = HarcLibraryMode(rawValue: snapshot.modeRawValue) {
            mode = restoredMode
        }
        notesExpanded = snapshot.notesExpanded
        projectsExpanded = snapshot.projectsExpanded
        peopleExpanded = snapshot.peopleExpanded
        recordingsExpanded = snapshot.recordingsExpanded
        expandedNoteBuckets = Set(snapshot.expandedNoteBuckets)
        knownNoteBucketIDs = Set(snapshot.knownNoteBuckets)
        restoredSelection = snapshot.selection?.librarySelection
        if let restoredSelection {
            selection = restoredSelection
        }
    }

    private func persistNavigationSnapshot() {
        LibraryNavigationStateStore.save(LibraryNavigationSnapshot(
            modeRawValue: mode.rawValue,
            selection: selection.map(PersistedLibrarySelection.init),
            notesExpanded: notesExpanded,
            projectsExpanded: projectsExpanded,
            peopleExpanded: peopleExpanded,
            recordingsExpanded: recordingsExpanded,
            expandedNoteBuckets: expandedNoteBuckets.sorted(),
            knownNoteBuckets: knownNoteBucketIDs.sorted()
        ))
    }

    private func restoreOrValidateSelection() {
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
    private var searchResultsList: some View {
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

    private var contextSearchHeader: some View {
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

    /// A `Label`-style row for use inside a `List(selection:)`. The tag is
    /// `wavPath` to match `selection`.
    private func recordingLabel(_ rec: Recording) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                if let endedAt = rec.endedAt {
                    Text(Self.formatDuration(from: rec.startedAt, to: endedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                .foregroundStyle(rec.pinned ? Color.purple : Color.accentColor)
        }
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

    private func noteLabel(_ note: Note) -> some View {
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

    private func projectLabel(_ project: String) -> some View {
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
    }

    private func projectSubtitle(noteCount: Int, recordingCount: Int) -> String {
        let noteLabel = "\(noteCount) note\(noteCount == 1 ? "" : "s")"
        let recordingLabel = "\(recordingCount) recording\(recordingCount == 1 ? "" : "s")"
        return "\(noteLabel) · \(recordingLabel)"
    }

    @ViewBuilder
    private func contextMenu(for rec: Recording) -> some View {
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

    private func presentExport(_ recording: Recording) {
        exportDraft = RecordingExportDraft(includeSummary: prefs.includeSummaryInPrompt)
        exportRecording = recording
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        detailBody
            .safeAreaInset(edge: .top, spacing: 0) {
                if let mutationFailure {
                    mutationFailureBanner(mutationFailure)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
            }
    }

    @ViewBuilder
    private var detailBody: some View {
        switch mode {
        case .library:
            libraryDetail
        case .wiki:
            wikiDetail
        case .review:
            reviewDetail
        }
    }

    private func mutationFailureBanner(_ failure: LibraryMutationFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.caption.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button {
                mutationFailure = nil
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var libraryDetail: some View {
        switch selection {
        case .note:
            if let note = selectedNote {
                noteDetail(note: note)
            } else {
                ContentUnavailableView(
                    "No Note Selected",
                    systemImage: "note.text",
                    description: Text("Pick a note from the sidebar.")
                )
            }
        case .person(let id):
            PersonDetailView(
                personID: id,
                store: store,
                onSelectRecording: { recID, _ in
                    // Swap to the recording's detail pane when the user taps an utterance.
                    if let rec = libraryVM.recordings.first(where: { $0.id == recID }) {
                        selection = .recording(wavPath: rec.wavPath)
                    }
                },
                onPersonDeleted: { selection = nil }
            )
        case .project(let name):
            projectDetail(name: name)
        case .recording, .none:
            if let recording = selectedRecording {
                detailContent(recording: recording)
                    .inspector(isPresented: $inspectorOpen) {
                        inspectorContent(recording: recording)
                    }
            } else {
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "sidebar.left",
                    description: Text("Pick a note, project, person, or recording from the sidebar.")
                )
            }
        }
    }

    private var wikiDetail: some View {
        let pages = wikiPages.filter { $0.section == wikiSection }
        let selectedPage = selectedWikiPageID.flatMap { id in wikiPages.first { $0.id == id } }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(wikiSection.title, systemImage: wikiSection.systemImage)
                        .font(.title.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await scanConnectedSources() }
                    } label: {
                        Label("Scan Sources", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(prefs.sourceRoots.isEmpty)
                }

                if let sourceScanStatus {
                    Text(sourceScanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let wikiLoadError {
                    Label(wikiLoadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.red)
                } else if let selectedPage {
                    wikiPageView(selectedPage)
                } else if pages.isEmpty {
                    wikiEmptyState(for: wikiSection)
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(pages) { page in
                            Button {
                                selectedWikiPageID = page.id
                            } label: {
                                wikiPageRow(page)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(wikiSection.title)
    }

    private var reviewDetail: some View {
        let selected = selectedReviewProposalID.flatMap { id in reviewProposals.first { $0.id == id } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Review", systemImage: "checklist")
                        .font(.title.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await loadReviewProposals() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                if let reviewLoadError {
                    Label(reviewLoadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.red)
                } else if let selected {
                    reviewProposalView(selected)
                } else if reviewProposals.isEmpty {
                    reviewEmptyState
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(reviewProposals) { proposal in
                            Button {
                                selectedReviewProposalID = proposal.id
                            } label: {
                                reviewProposalRow(proposal)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Review")
    }

    private func projectDetail(name: String) -> some View {
        let relatedNotes = notesForProject(name)
        let relatedRecordings = recordingsForProject(name)

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(name, systemImage: "folder")
                        .font(.title.weight(.semibold))
                    Text(projectSubtitle(noteCount: relatedNotes.count, recordingCount: relatedRecordings.count))
                        .foregroundStyle(.secondary)
                }

                if relatedNotes.isEmpty && relatedRecordings.isEmpty {
                    ContentUnavailableView(
                        "No Project Context",
                        systemImage: "folder",
                        description: Text("Use @project[\(name)] or a project:\(name) tag in a note to connect work here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    if !relatedNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes")
                                .font(.headline)
                            ForEach(relatedNotes) { note in
                                Button {
                                    selection = .note(id: note.id)
                                } label: {
                                    projectNoteRow(note)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !relatedRecordings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recordings")
                                .font(.headline)
                            ForEach(relatedRecordings) { recording in
                                Button {
                                    selection = .recording(wavPath: recording.wavPath)
                                } label: {
                                    projectRecordingRow(recording)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(name)
    }

    private func projectNoteRow(_ note: Note) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func projectRecordingRow(_ recording: Recording) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.displayTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(recording.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func wikiPageRow(_ page: WikiPage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: page.section.systemImage)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(page.fileURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(Self.relativeDate(page.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func wikiPageView(_ page: WikiPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                    Text(page.fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([page.fileURL])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }

            Text(page.body)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func wikiEmptyTitle(for section: WikiSection) -> String {
        switch section {
        case .overview: return "No Wiki Overview"
        case .index: return "No Wiki Index"
        case .topics: return "No Topics Yet"
        case .people: return "No People Pages"
        case .projects: return "No Project Pages"
        case .sources: return "No Source Summaries"
        case .decisions: return "No Decisions"
        case .contradictions: return "No Contradictions"
        case .openQuestions: return "No Open Questions"
        }
    }

    private func wikiEmptyDescription(for section: WikiSection) -> String {
        switch section {
        case .overview, .index:
            return "Approve review proposals to let Harc build this compiled knowledge surface."
        case .sources:
            return prefs.sourceRoots.isEmpty
                ? "Add a read-only source folder in Settings, then scan it from Wiki."
                : "Scan connected source folders to create reviewable summaries."
        case .decisions, .contradictions, .openQuestions:
            return "These pages appear after Harc reviews meetings, notes, and source folders for durable knowledge."
        case .topics, .people, .projects:
            return "Record meetings, write notes, or ingest repos to generate pages for this section."
        }
    }

    private func wikiEmptyState(for section: WikiSection) -> some View {
        VStack(spacing: 14) {
            EmptyStateView(
                icon: section.systemImage,
                title: wikiEmptyTitle(for: section),
                subtitle: "\(section.title) pages are compiled from approved review proposals, recordings, notes, and connected source folders."
            )
            prerequisiteGrid([
                ("Notes", "\(notes.count)", !notes.isEmpty),
                ("Recordings", "\(libraryVM.recordings.count)", !libraryVM.recordings.isEmpty),
                ("Source folders", "\(prefs.sourceRoots.count)", !prefs.sourceRoots.isEmpty),
                ("Review proposals", "\(reviewProposals.count)", !reviewProposals.isEmpty),
            ])
            HStack(spacing: 8) {
                Button("Create Note") { createBlankNote() }
                    .buttonStyle(.bordered)
                Button("Record") { bridge.onStartStop() }
                    .buttonStyle(.bordered)
                Button("Add Source Folder") { openSettings() }
                    .buttonStyle(.bordered)
                Button("Scan Sources") { Task { await scanConnectedSources() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(prefs.sourceRoots.isEmpty)
            }
        }
    }

    private var reviewEmptyState: some View {
        VStack(spacing: 14) {
            EmptyStateView(
                icon: "checklist",
                title: "No Wiki Updates",
                subtitle: "Review turns recordings, notes, and source folders into proposed wiki pages before they become durable knowledge."
            )
            prerequisiteGrid([
                ("Notes", "\(notes.count)", !notes.isEmpty),
                ("Recordings", "\(libraryVM.recordings.count)", !libraryVM.recordings.isEmpty),
                ("Source folders", "\(prefs.sourceRoots.count)", !prefs.sourceRoots.isEmpty),
                ("Pending proposals", "\(reviewProposals.filter { $0.status == .pending || $0.status == .edited }.count)", false),
            ])
            HStack(spacing: 8) {
                Button("Create Note") { createBlankNote() }
                    .buttonStyle(.bordered)
                Button("Record") { bridge.onStartStop() }
                    .buttonStyle(.bordered)
                Button("Add Source Folder") { openSettings() }
                    .buttonStyle(.bordered)
                Button("Scan Sources") { Task { await scanConnectedSources() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(prefs.sourceRoots.isEmpty)
            }
        }
    }

    private func prerequisiteGrid(_ rows: [(String, String, Bool)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Image(systemName: row.2 ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.2 ? Color.green : Color.secondary)
                    Text(row.0)
                        .foregroundStyle(.secondary)
                    Text(row.1)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(row.2 ? Color.primary : Color.secondary)
                }
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func reviewBucket(_ title: String, statuses: [WikiReviewProposalStatus]) -> some View {
        let items = reviewProposals.filter { statuses.contains($0.status) }
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ForEach(items) { proposal in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(proposal.title)
                            .lineLimit(1)
                        Text(proposal.status.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: reviewIcon(for: proposal))
                        .foregroundStyle(reviewColor(for: proposal))
                }
                .tag(Optional(proposal.id))
            }
        }
    }

    private func reviewProposalRow(_ proposal: WikiReviewProposal) -> some View {
        HStack(spacing: 10) {
            Image(systemName: reviewIcon(for: proposal))
                .foregroundStyle(reviewColor(for: proposal))
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(proposal.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(proposal.status.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func reviewProposalView(_ proposal: WikiReviewProposal) -> some View {
        let busy = reviewActionInFlight.contains(proposal.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.title)
                        .font(.title2.weight(.semibold))
                    Text("\(proposal.kind.rawValue) · \(proposal.status.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await approveReviewProposal(proposal) }
                } label: {
                    Label(busy ? "Working" : "Approve", systemImage: busy ? "hourglass" : "checkmark.circle")
                }
                .disabled(busy || proposal.status == .approved || proposal.status == .dismissed)

                Button(role: .destructive) {
                    Task { await dismissReviewProposal(proposal) }
                } label: {
                    Label("Dismiss", systemImage: "xmark.circle")
                }
                .disabled(busy || proposal.status == .approved || proposal.status == .dismissed)
            }

            if let status = reviewActionStatus[proposal.id] {
                HStack(spacing: 8) {
                    Label(status, systemImage: reviewActionStatusIcon(status))
                        .font(.caption)
                        .foregroundStyle(status.localizedCaseInsensitiveContains("failed") ? Color.red : Color.secondary)
                    if let pageID = reviewApprovedPageID[proposal.id] {
                        Button("Open Page") {
                            mode = .wiki
                            selectedWikiPageID = pageID
                            wikiSection = proposal.targetSection
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Text(proposal.summary)
                .foregroundStyle(.secondary)

            if !proposal.sourceCitations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources")
                        .font(.headline)
                    ForEach(proposal.sourceCitations, id: \.self) { citation in
                        Text(citation)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()

            Text(proposal.proposedMarkdown)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reviewIcon(for proposal: WikiReviewProposal) -> String {
        switch proposal.status {
        case .pending: return "circle"
        case .edited: return "pencil.circle"
        case .approved: return "checkmark.circle.fill"
        case .dismissed: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func reviewColor(for proposal: WikiReviewProposal) -> Color {
        switch proposal.status {
        case .pending, .edited: return Color.accentColor
        case .approved: return Color.green
        case .dismissed: return Color.secondary
        case .failed: return Color.red
        }
    }

    private func reviewActionStatusIcon(_ status: String) -> String {
        status.localizedCaseInsensitiveContains("failed")
            ? "exclamationmark.triangle"
            : "info.circle"
    }

    private func noteDetail(note: Note) -> some View {
        let recordingToolbarState = NoteRecordingToolbarState.resolve(
            isRecording: recordingState.isRecording,
            activeNoteID: bridge.activeNoteRecordingID,
            currentNoteID: note.id
        )
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: Binding(
                    get: { noteTitleDraft },
                    set: {
                        noteTitleDraft = $0
                        markNoteEdited()
                    }
                ))
                .font(.title.weight(.semibold))
                .textFieldStyle(.plain)

                HStack(spacing: 8) {
                    Label("Markdown", systemImage: "doc.plaintext")
                    if !note.recordings.isEmpty {
                        Label("\(note.recordings.count) recording\(note.recordings.count == 1 ? "" : "s")", systemImage: "waveform")
                    }
                    if !note.attachments.isEmpty {
                        Label(attachmentStatusText(for: note), systemImage: "photo")
                    }
                    if noteSaving {
                        Label("Saving", systemImage: "arrow.triangle.2.circlepath")
                    } else if noteDirty {
                        Text("Unsaved")
                    } else if let noteSavedAt {
                        Text("Saved \(noteSavedAt, style: .relative)")
                    } else {
                        Label("Saved", systemImage: "checkmark")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("Editor Mode", selection: $noteEditorMode) {
                    ForEach(NoteMarkdownEditorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                noteAttachmentsStrip(note: note)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            noteEditorSurface(note: note)
                .frame(minHeight: 360, maxHeight: .infinity)
                .layoutPriority(1)

            noteLinksSection(note: note)

            if let noteSaveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(noteSaveError)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(Color.red)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
            }

            if let noteSaveConflict, noteSaveConflict.noteID == note.id {
                noteSaveConflictBanner(noteSaveConflict)
            }

            if let feedback = bridge.noteRecordingLinkFeedback, feedback.noteID == note.id {
                noteRecordingLinkBanner(feedback)
            }

            if let conflict = bridge.noteRecordingConflict, conflict.requestedNoteID == note.id {
                noteRecordingConflictBanner(conflict)
            }

            if !unresolvedBarePersonMentions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text("Unlinked people mentions: \(unresolvedBarePersonMentions.joined(separator: ", ")). Use @[Name] to create a Person.")
                    Spacer()
                    Button("Dismiss") { unresolvedBarePersonMentions = [] }
                        .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.08))
            }
        }
        .navigationTitle(note.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    if recordingToolbarState.canToggleDirectly {
                        if noteDirty {
                            saveSelectedNote()
                        }
                        bridge.onStartRecordingForNote(note.id)
                    } else {
                        bridge.showNoteRecordingConflict(requestedNoteID: note.id)
                    }
                } label: {
                    Label(
                        recordingToolbarState.title,
                        systemImage: recordingToolbarState.systemImage
                    )
                }
                .tint(recordingToolbarState == .recordingIntoThisNote ? HarcBrand.live : nil)

                Button {
                    saveSelectedNote()
                } label: {
                    Label("Save Note", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!noteDirty)

                Button {
                    toggleNotePin(note)
                } label: {
                    Label(note.pinned ? "Unpin Note" : "Pin Note", systemImage: note.pinned ? "pin.fill" : "pin")
                }
                .help(note.pinned ? "Unpin note" : "Pin note")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }

                Button(role: .destructive) {
                    pendingDeleteNote = note
                } label: {
                    Label("Delete Note", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func noteEditorSurface(note: Note) -> some View {
        switch noteEditorMode {
        case .source:
            noteTextEditorSurface(font: .system(.body, design: .monospaced))

        case .live:
            NoteMarkdownWebView(text: Binding(
                get: { noteBodyDraft },
                set: {
                    noteBodyDraft = $0
                    markNoteEdited()
                }
            ), mode: .live,
               linkTargets: noteLinkTargets(for: note),
               mentionTargets: noteMentionTargets(),
               attachmentBaseURL: note.fileURL.deletingLastPathComponent(),
               onPasteImage: { image in
                   try await pasteImage(image, into: note.id)
               })
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("Live Markdown note editor")
            .accessibilityIdentifier("harc.note.liveMarkdownEditor")

        case .read:
            noteRenderedMarkdownSurface()
            .accessibilityLabel("Markdown note preview")
            .accessibilityIdentifier("harc.note.markdownPreview")
        }
    }

    private func noteTextEditorSurface(font: Font) -> some View {
        ZStack(alignment: .topLeading) {
            if noteBodyDraft.isEmpty {
                Text("Start writing in Markdown...")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .allowsHitTesting(false)
            }

            TextEditor(text: Binding(
                get: { noteBodyDraft },
                set: {
                    noteBodyDraft = $0
                    markNoteEdited()
                }
            ))
            .font(font)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("Markdown note editor")
            .accessibilityIdentifier("harc.note.markdownTextEditor")
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func noteRenderedMarkdownSurface() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if noteBodyDraft.isEmpty {
                    Text("Start writing in Markdown...")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(notePreviewBlocks(noteBodyDraft).enumerated()), id: \.offset) { _, block in
                        notePreviewBlockView(block)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func notePreviewBlocks(_ markdown: String) -> [NoteMarkdownPreviewRenderer.Block] {
        NoteMarkdownPreviewRenderer.blocks(markdown)
    }

    @ViewBuilder
    private func notePreviewBlockView(_ block: NoteMarkdownPreviewRenderer.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.content)
                .font(level <= 1 ? .title.bold() : level == 2 ? .title2.bold() : .title3.bold())
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph:
            Text(block.content)
                .font(.body)
        case .unorderedListItem:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(block.content)
            }
            .font(.body)
        case .orderedListItem(let number):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .monospacedDigit()
                Text(block.content)
            }
            .font(.body)
        case .quote:
            Text(block.content)
                .font(.body.italic())
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 3)
                }
        case .thematicBreak:
            Divider()
                .padding(.vertical, 6)
        case .code:
            Text(block.content)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func noteRecordingLinkBanner(_ feedback: NoteRecordingLinkFeedback) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.isRecoveryNeeded ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(feedback.isRecoveryNeeded ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(feedback.isRecoveryNeeded ? "Recording needs note link" : "Recording linked")
                    .font(.caption.weight(.semibold))
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if feedback.isRecoveryNeeded {
                        Button("Attach latest recording") {
                            bridge.onAttachLatestRecordingToNote(feedback.noteID)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if feedback.canOpenRecording {
                        Button("Open recording") {
                            bridge.onOpenNoteLinkedRecording(feedback)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if feedback.canRevealFile {
                        Button("Reveal file") {
                            bridge.onRevealNoteLinkedRecordingFile(feedback)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                bridge.clearNoteRecordingLinkFeedback()
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background((feedback.isRecoveryNeeded ? Color.orange : Color.green).opacity(0.08))
    }

    private func noteRecordingConflictBanner(_ conflict: NoteRecordingConflict) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "record.circle")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording already active")
                    .font(.caption.weight(.semibold))
                Text(conflict.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Button("Open active recording") {
                        bridge.onOpenWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Dismiss") {
                        bridge.clearNoteRecordingConflict()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private func noteSaveConflictBanner(_ conflict: NoteSaveConflict) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Note changed on disk")
                    .font(.caption.weight(.semibold))
                Text("Reload the file version saved \(conflict.diskUpdatedAt, style: .relative), or overwrite it with your current draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Button("Reload File") {
                        reloadConflictedNote(conflict)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Overwrite") {
                        overwriteConflictedNote(conflict)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Dismiss") {
                        noteSaveConflict = nil
                        noteSaveError = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private func noteLinksSection(note: Note) -> some View {
        let links = resolvedWikilinks(in: noteBodyDraft, currentNoteID: note.id)
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Label("Links", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if links.isEmpty {
                    Text("Type [[ to link a note or recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !links.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(links) { link in
                            Button {
                                openWikilink(link)
                            } label: {
                                Label(link.title, systemImage: link.iconName)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!link.isResolved)
                            .help(link.helpText)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func detailContent(recording: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WaveformPlayerView(
                        envelope: detailEnvelope,
                        audioURL: URL(fileURLWithPath: recording.wavPath)
                    )
                    .padding(.horizontal)

                    inspectorSummaryChips(for: recording)
                        .padding(.horizontal)

                    // Summary card — requires SummarizationQueueStore and
                    // ModelManagerStore injected as environment objects by the
                    // window controller.
                    SummaryCardView(
                        recording: recording,
                        store: store,
                        activeSummarizerID: prefs.activeSummarizerID,
                        hasTranscript: hasTranscriptSource(recording),
                        onClearSummary: { id in
                            Task {
                                do {
                                    try await store.clearSummaryStatus(id: id)
                                    mutationFailure = nil
                                } catch {
                                    reportMutationFailure(.clearSummary(recording.displayTitle), error: error)
                                }
                            }
                        }
                    )
                    .padding(.horizontal)

                    if transcriptFindVisible {
                        transcriptFindBar(proxy: proxy)
                            .padding(.horizontal)
                    }

                    // Transcript text
                    transcriptBody(proxy: proxy)
                        .padding(.horizontal)
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(transcriptKeyboardShortcuts(proxy: proxy))
        }
        .navigationTitle(recording.displayTitle)
        // Reload transcript when the selection's recording row changes in the DB.
        .task(id: recording.wavPath) {
            await observeRecording(recording: recording)
            await loadInspectorSummaryData(for: recording)
        }
        .onChange(of: transcriptSearchText) { _, _ in
            transcriptSearchIndex = 0
        }
    }

    private func inspectorSummaryChips(for recording: Recording) -> some View {
        let speakerCount = speakerIndices(for: recording).count
        let fileCount = [recording.wavPath, recording.txtPath, recording.jsonPath].compactMap(\.self).count
        return HStack(spacing: 8) {
            inspectorChip(
                title: inspectorPendingSuggestions.isEmpty ? "\(speakerCount) speakers" : "\(inspectorPendingSuggestions.count) speaker review",
                icon: inspectorPendingSuggestions.isEmpty ? "person.wave.2" : "person.crop.circle.badge.questionmark",
                tint: inspectorPendingSuggestions.isEmpty ? .secondary : .yellow
            )
            inspectorChip(
                title: linkedNotes.isEmpty ? "No linked notes" : "\(linkedNotes.count) linked notes",
                icon: linkedNotes.isEmpty ? "note.text" : "note.text.badge.plus",
                tint: linkedNotes.isEmpty ? .secondary : .accentColor
            )
            inspectorChip(
                title: "\(fileCount) files",
                icon: "folder",
                tint: .secondary
            )
            Spacer(minLength: 0)
        }
    }

    private func inspectorChip(title: String, icon: String, tint: Color) -> some View {
        Button {
            inspectorOpen = true
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
    }

    @ViewBuilder
    private func transcriptBody(proxy: ScrollViewProxy) -> some View {
        if let err = transcriptLoadError {
            Text(err)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !transcriptSegments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(transcriptSegments) { seg in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(formatTimestamp(seconds: seg.startSec))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.10), in: Capsule())
                            Text(seg.speakerName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    Text(highlightedTranscriptText(seg.text, activeMatch: activeTranscriptMatch(for: seg.id)))
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(seg.id)
                    .padding(.vertical, activeTranscriptMatchSegmentID == seg.id ? 6 : 0)
                    .padding(.horizontal, activeTranscriptMatchSegmentID == seg.id ? 8 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(activeTranscriptMatchSegmentID == seg.id ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                }
            }
        } else if transcriptText.isEmpty {
            EmptyStateView(
                icon: "doc.text.magnifyingglass",
                title: "No transcript available",
                subtitle: "Transcribe this recording to make the transcript searchable and editable."
            )
        } else {
            Text(highlightedTranscriptText(transcriptText, activeMatch: activeTranscriptMatch))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("flat-transcript")
        }
    }

    private func transcriptFindBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
            TextField("Find in transcript", text: $transcriptSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($transcriptSearchFocused)
                .onSubmit { jumpToNextTranscriptMatch(proxy: proxy) }
            Text(transcriptSearchStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            Button {
                jumpToPreviousTranscriptMatch(proxy: proxy)
            } label: {
                Label("Previous match", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSearchMatches.isEmpty)
            .help("Previous match")
            Button {
                jumpToNextTranscriptMatch(proxy: proxy)
            } label: {
                Label("Next match", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSearchMatches.isEmpty)
            .help("Next match")
            Divider()
                .frame(height: 18)
            Button {
                jumpToPreviousSpeakerBoundary(proxy: proxy)
            } label: {
                Label("Previous speaker", systemImage: "person.fill.turn.up.left")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSegments.isEmpty)
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .help("Previous speaker change (⌘↑)")
            Button {
                jumpToNextSpeakerBoundary(proxy: proxy)
            } label: {
                Label("Next speaker", systemImage: "person.fill.turn.down.right")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSegments.isEmpty)
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .help("Next speaker change (⌘↓)")
            Button {
                transcriptSearchText = ""
                transcriptFindVisible = false
            } label: {
                Label("Close find", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close find")
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func transcriptKeyboardShortcuts(proxy: ScrollViewProxy) -> some View {
        HStack {
            Button("Find in transcript") {
                transcriptFindVisible = true
                transcriptSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button("Next speaker") {
                jumpToNextSpeakerBoundary(proxy: proxy)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Previous speaker") {
                jumpToPreviousSpeakerBoundary(proxy: proxy)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var transcriptSearchQuery: String {
        transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcriptSearchMatches: [TranscriptSearchMatch] {
        let query = transcriptSearchQuery
        guard !query.isEmpty else { return [] }

        if !transcriptSegments.isEmpty {
            return transcriptSegments.flatMap { segment in
                TranscriptFind.matches(in: segment.text, query: query, segmentID: segment.id)
            }
        }

        return TranscriptFind.matches(in: transcriptText, query: query)
    }

    private var transcriptSearchStatus: String {
        let matches = transcriptSearchMatches
        guard !transcriptSearchQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return "0/0" }
        return "\(min(transcriptSearchIndex + 1, matches.count))/\(matches.count)"
    }

    private var activeTranscriptMatchSegmentID: UUID? {
        activeTranscriptMatch?.segmentID
    }

    private var activeTranscriptMatch: TranscriptSearchMatch? {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(transcriptSearchIndex, matches.count - 1)]
    }

    private func activeTranscriptMatch(for segmentID: UUID) -> TranscriptSearchMatch? {
        guard let match = activeTranscriptMatch, match.segmentID == segmentID else { return nil }
        return match
    }

    private func jumpToNextTranscriptMatch(proxy: ScrollViewProxy) {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + 1) % matches.count
        scrollToTranscriptMatch(matches[transcriptSearchIndex], proxy: proxy)
    }

    private func jumpToPreviousTranscriptMatch(proxy: ScrollViewProxy) {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + matches.count - 1) % matches.count
        scrollToTranscriptMatch(matches[transcriptSearchIndex], proxy: proxy)
    }

    private func scrollToTranscriptMatch(_ match: TranscriptSearchMatch, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if let segmentID = match.segmentID {
                proxy.scrollTo(segmentID, anchor: .center)
            } else {
                proxy.scrollTo("flat-transcript", anchor: .center)
            }
        }
    }

    private func jumpToNextSpeakerBoundary(proxy: ScrollViewProxy) {
        guard let id = nextSpeakerBoundaryID(forward: true) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func jumpToPreviousSpeakerBoundary(proxy: ScrollViewProxy) {
        guard let id = nextSpeakerBoundaryID(forward: false) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func nextSpeakerBoundaryID(forward: Bool) -> UUID? {
        let boundaries = transcriptSegments.indices.dropFirst().compactMap { index -> UUID? in
            transcriptSegments[index].speaker == transcriptSegments[index - 1].speaker
                ? nil
                : transcriptSegments[index].id
        }
        guard !boundaries.isEmpty else { return transcriptSegments.first?.id }

        let activeID = activeTranscriptMatchSegmentID
        let activeIndex = activeID.flatMap { id in transcriptSegments.firstIndex { $0.id == id } } ?? 0

        if forward {
            return transcriptSegments[activeIndex...].dropFirst().first { segment in
                boundaries.contains(segment.id)
            }?.id ?? boundaries.first
        }

        return transcriptSegments[..<max(activeIndex, 1)].reversed().first { segment in
            boundaries.contains(segment.id)
        }?.id ?? boundaries.last
    }

    private func highlightedTranscriptText(_ text: String, activeMatch: TranscriptSearchMatch?) -> AttributedString {
        let query = transcriptSearchQuery
        guard !query.isEmpty else { return AttributedString(text) }

        let highlighted = NSMutableAttributedString(string: text)
        for match in TranscriptFind.matches(in: text, query: query, segmentID: activeMatch?.segmentID) {
            let isActive = activeMatch?.range == match.range
            highlighted.addAttribute(
                .backgroundColor,
                value: NSColor.selectedTextBackgroundColor.withAlphaComponent(isActive ? 0.72 : 0.30),
                range: match.range
            )
            if isActive {
                highlighted.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
        }
        return AttributedString(highlighted)
    }

    private func formatTimestamp(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds / 60) % 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Inspector

    private func inspectorContent(recording: Recording) -> some View {
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

    private func loadInspectorSummaryData(for recording: Recording) async {
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

    private func linkedNotesSection(recording: Recording) -> some View {
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

    private func loadLinkedNotes(for recording: Recording) async {
        do {
            linkedNotes = try await NoteStore(rootURL: prefs.notesURL).fetchLinked(to: recording)
            linkedNotesError = nil
        } catch {
            linkedNotes = []
            linkedNotesError = error.localizedDescription
        }
    }

    private func createNote(for recording: Recording) {
        Task {
            do {
                let note = try await NoteStore(rootURL: prefs.notesURL).create(for: recording)
                linkedNotes = try await NoteStore(rootURL: prefs.notesURL).fetchLinked(to: recording)
                await loadNotes()
                mutationFailure = nil
                selection = .note(id: note.id)
                noteTitleDraft = note.title
                noteBodyDraft = note.body
                noteDirty = false
                linkedNotesError = nil
            } catch {
                linkedNotesError = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func openSettings() {
        bridge.onOpenSettings()
    }

    private var selectedNote: Note? {
        guard case .note(let id) = selection else { return nil }
        return notes.first(where: { $0.id == id })
    }

    private func loadNotes(resetDraft: Bool = true) async {
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

    private func searchNotes() async {
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

    private func loadWikiPages() async {
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

    private func loadReviewProposals() async {
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

    private func scanConnectedSources() async {
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
                    _ = try await reviewStore.upsert(proposal)
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

    private func approveReviewProposal(_ proposal: WikiReviewProposal) async {
        reviewActionInFlight.insert(proposal.id)
        reviewActionStatus[proposal.id] = "Approving..."
        defer { reviewActionInFlight.remove(proposal.id) }

        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )
        do {
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

    private func dismissReviewProposal(_ proposal: WikiReviewProposal) async {
        reviewActionInFlight.insert(proposal.id)
        reviewActionStatus[proposal.id] = "Dismissing..."
        defer { reviewActionInFlight.remove(proposal.id) }

        let wikiRoot = prefs.notesURL.deletingLastPathComponent().appendingPathComponent("Wiki", isDirectory: true)
        let reviewStore = WikiReviewStore(
            fileURL: wikiRoot.appendingPathComponent(".review/proposals.json"),
            wikiStore: HarcWikiStore(rootURL: wikiRoot)
        )
        do {
            _ = try await reviewStore.updateStatus(id: proposal.id, status: .dismissed)
            reviewActionStatus[proposal.id] = "Dismissed."
            await loadReviewProposals()
        } catch {
            reviewActionStatus[proposal.id] = "Dismiss failed: \(error.localizedDescription)"
        }
    }

    private func loadSelectedNoteDraft() {
        guard let note = selectedNote else { return }
        noteTitleDraft = note.title
        noteBodyDraft = note.body
        noteDirty = false
        noteSaving = false
        noteSavedAt = note.updatedAt
        noteLastLoadedUpdatedAt = note.updatedAt
        noteSaveError = nil
        noteSaveConflict = nil
    }

    private func markNoteEdited() {
        noteSaveGeneration += 1
        noteDirty = true
        noteSaveError = nil
        noteSaveConflict = nil
        scheduleNoteAutosave()
    }

    private func scheduleNoteAutosave() {
        noteAutosaveTask?.cancel()
        guard case .note(let id) = selection else { return }
        let request = NoteSaveRequest(
            id: id,
            title: noteTitleDraft,
            body: noteBodyDraft,
            generation: noteSaveGeneration,
            baseUpdatedAt: noteLastLoadedUpdatedAt,
            updateDraftIfSelected: true
        )
        noteAutosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            guard request.generation == noteSaveGeneration else { return }
            await saveNoteDraft(request)
        }
    }

    private func createBlankNote() {
        Task {
            do {
                let note = try await NoteStore(rootURL: prefs.notesURL).create()
                await loadNotes()
                selection = .note(id: note.id)
                noteTitleDraft = note.title
                noteBodyDraft = note.body
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

    private func archiveNote(_ note: Note) {
        pendingDeleteNote = nil
        noteAutosaveTask?.cancel()
        Task {
            do {
                try await NoteStore(rootURL: prefs.notesURL).archive(id: note.id)
                try? await store.deleteKnowledgeChunks(sourceKind: .note, sourceID: note.id)
                if selection == .note(id: note.id) {
                    selection = nil
                    noteTitleDraft = ""
                    noteBodyDraft = ""
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

    private func toggleNotePin(_ note: Note) {
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

    private func saveSelectedNote() {
        guard case .note(let id) = selection else { return }
        noteAutosaveTask?.cancel()
        let request = NoteSaveRequest(
            id: id,
            title: noteTitleDraft,
            body: noteBodyDraft,
            generation: noteSaveGeneration,
            baseUpdatedAt: noteLastLoadedUpdatedAt,
            updateDraftIfSelected: true
        )
        Task {
            await saveNoteDraft(request)
        }
    }

    private func flushOutgoingNoteIfNeeded(_ oldSelection: LibrarySelection?) {
        guard case .note(let id) = oldSelection, noteDirty else { return }
        noteAutosaveTask?.cancel()
        let request = NoteSaveRequest(
            id: id,
            title: noteTitleDraft,
            body: noteBodyDraft,
            generation: noteSaveGeneration,
            baseUpdatedAt: noteLastLoadedUpdatedAt,
            updateDraftIfSelected: false
        )
        Task {
            await saveNoteDraft(request)
        }
    }

    private func saveNoteDraft(_ request: NoteSaveRequest, allowOverwrite: Bool = false) async {
        guard var note = notes.first(where: { $0.id == request.id }) else { return }
        let noteStore = NoteStore(rootURL: prefs.notesURL)
        let diskNote = try? await noteStore.fetch(id: request.id, includeArchived: true)
        switch NoteAutosaveGuard.shouldSave(
            request: request,
            currentGeneration: noteSaveGeneration,
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
               request.generation == noteSaveGeneration || allowOverwrite {
                noteTitleDraft = saved.title
                noteBodyDraft = saved.body
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

    private var selectedNoteID: String? {
        if case .note(let id) = selection { return id }
        return nil
    }

    private func reloadConflictedNote(_ conflict: NoteSaveConflict) {
        Task {
            do {
                guard let note = try await NoteStore(rootURL: prefs.notesURL).fetch(id: conflict.noteID, includeArchived: true) else {
                    noteSaveError = "Could not reload the note from disk."
                    return
                }
                if selection == .note(id: conflict.noteID) {
                    noteTitleDraft = note.title
                    noteBodyDraft = note.body
                    noteDirty = false
                    noteSaving = false
                    noteSavedAt = note.updatedAt
                    noteLastLoadedUpdatedAt = note.updatedAt
                    noteSaveError = nil
                    noteSaveConflict = nil
                    noteSaveGeneration += 1
                }
                await loadNotes(resetDraft: false)
            } catch {
                noteSaveError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func pasteImage(_ image: NotePastedImage, into noteID: String) async throws -> String {
        let result = try await NoteStore(rootURL: prefs.notesURL).attachImage(
            toNoteID: noteID,
            data: image.data,
            mimeType: image.mimeType,
            preferredFilename: image.filename
        )
        await loadNotes(resetDraft: false)
        if selection == .note(id: noteID) {
            noteSavedAt = result.note.updatedAt
            noteLastLoadedUpdatedAt = result.note.updatedAt
            noteSaveError = nil
        }
        startCaptionIfAvailable(noteID: noteID, attachmentID: result.attachment.id)
        return result.markdown
    }

    private func attachmentStatusText(for note: Note) -> String {
        let count = note.attachments.count
        let captioned = note.attachments.filter { $0.captionStatus == .captioned }.count
        if captioned > 0 {
            return "\(count) image\(count == 1 ? "" : "s"), \(captioned) captioned"
        }
        return "\(count) image\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func noteAttachmentsStrip(note: Note) -> some View {
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

    private func attachmentMenuTitle(_ attachment: NoteAttachment) -> String {
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

    private func attachmentIconName(_ attachment: NoteAttachment) -> String {
        if captioningAttachmentIDs.contains(attachment.id) { return "sparkles" }
        switch attachment.captionStatus {
        case .captioned: return "photo.badge.checkmark"
        case .failed: return "photo.badge.exclamationmark"
        case .pending: return "sparkles"
        case .unavailable: return "photo"
        }
    }

    private func attachmentURL(_ attachment: NoteAttachment, in note: Note) -> URL {
        note.fileURL.deletingLastPathComponent().appendingPathComponent(attachment.relativePath)
    }

    private func revealAttachment(_ attachment: NoteAttachment, in note: Note) {
        NSWorkspace.shared.activateFileViewerSelecting([attachmentURL(attachment, in: note)])
    }

    private func copyAttachmentImage(_ attachment: NoteAttachment, in note: Note) {
        guard let image = NSImage(contentsOf: attachmentURL(attachment, in: note)) else {
            noteSaveError = "Could not load image for copying."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func removeAttachment(_ attachment: NoteAttachment, from note: Note) {
        Task {
            do {
                let saved = try await NoteStore(rootURL: prefs.notesURL).removeAttachment(
                    noteID: note.id,
                    attachmentID: attachment.id
                )
                await loadNotes(resetDraft: false)
                if selection == .note(id: note.id) {
                    noteBodyDraft = saved.body
                    noteSavedAt = saved.updatedAt
                    noteLastLoadedUpdatedAt = saved.updatedAt
                    noteDirty = false
                }
            } catch {
                noteSaveError = error.localizedDescription
            }
        }
    }

    private func startCaptionIfAvailable(noteID: String, attachmentID: String) {
        let captionerID = ModelCatalog.descriptors(for: .visionCaptioner).first?.id
        guard let captionerID, modelStore.state(of: captionerID).isInstalled else { return }
        startCaption(noteID: noteID, attachmentID: attachmentID)
    }

    private func startCaption(noteID: String, attachmentID: String) {
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
                if let knowledgeIndexer {
                    Task.detached { [knowledgeIndexer, saved] in
                        try? await knowledgeIndexer.index(note: saved)
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

    private func overwriteConflictedNote(_ conflict: NoteSaveConflict) {
        noteSaveConflict = nil
        noteSaveError = nil
        let request = NoteSaveRequest(
            id: conflict.noteID,
            title: conflict.draftTitle,
            body: conflict.draftBody,
            generation: noteSaveGeneration,
            baseUpdatedAt: nil,
            updateDraftIfSelected: true
        )
        Task {
            await saveNoteDraft(request, allowOverwrite: true)
        }
    }

    private func reportMutationFailure(_ action: LibraryMutationAction, error: Error) {
        mutationFailure = LibraryMutationFailure(action: action, error: error)
    }

    private func noteMentionTargets() -> [NoteMarkdownLinkTarget] {
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

    private func loadNoteMentionPeople() async {
        noteMentionPeople = (try? await store.fetchPeople()) ?? []
    }

    private func ensureMentionedPeople(in body: String) async throws -> [String] {
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

    private func noteLinkTargets(for currentNote: Note) -> [NoteMarkdownLinkTarget] {
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

    private func resolvedWikilinks(in body: String, currentNoteID: String) -> [ResolvedWikilink] {
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

    private func openWikilink(_ link: ResolvedWikilink) {
        switch link.target {
        case .note(let id):
            selection = .note(id: id)
        case .recording(let wavPath):
            selection = .recording(wavPath: wavPath)
        case .unresolved:
            break
        }
    }

    private func extractWikilinkLabels(from body: String) -> [String] {
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

    private func extractProjectMentions(from body: String) -> [ProjectMention] {
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

    private func mergedProjectTags(existing tags: [String], body: String) -> [String] {
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

    private func inferredProjectNames() -> [String] {
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

    private func projectCounts(for project: String) -> (notes: Int, recordings: Int) {
        (notesForProject(project).count, recordingsForProject(project).count)
    }

    private func notesForProject(_ project: String) -> [Note] {
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

    private func recordingsForProject(_ project: String) -> [Recording] {
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

    private func normalizeWikilinkLabel(_ label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func deduplicatedLinkTargets(_ targets: [NoteMarkdownLinkTarget]) -> [NoteMarkdownLinkTarget] {
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

    private func deduplicatedMentionPeople(_ people: [Person]) -> [Person] {
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

    private func formatRecordingLinkDetail(_ recording: Recording) -> String {
        if let endedAt = recording.endedAt {
            return "Recording · \(Self.formatDuration(from: recording.startedAt, to: endedAt))"
        }
        return "Recording"
    }

    /// Resolved recording for the current selection, or nil when a Person is selected.
    private var selectedRecording: Recording? {
        guard case .recording(let wavPath) = selection else { return nil }
        // Check search hits first (they carry the same Recording), then the
        // main recordings list.
        if let hit = libraryVM.hits.first(where: { $0.recording.wavPath == wavPath }) {
            return hit.recording
        }
        return libraryVM.recordings.first { $0.wavPath == wavPath }
    }

    /// Alias used by the toolbar buttons; identical to `selectedRecording`.
    private var currentRecording: Recording? { selectedRecording }

    /// Copies the currently loaded transcript text to the system pasteboard.
    private func copyTranscript(_ recording: Recording) {
        let text = transcriptText.isEmpty ? (recording.transcriptText ?? "") : transcriptText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySearchContext() {
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

    private func answerSearchContext() {
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

    private func scopedContextMarkdown(for query: String) async throws -> String {
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

    private func selectedNoteContextMarkdown(_ note: Note, query: String) -> String {
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

    private func noteAttachmentContext(_ note: Note) -> String {
        let lines = note.attachments.compactMap { attachment -> String? in
            let text = attachment.searchableText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "- Image: \(text)"
        }
        guard !lines.isEmpty else { return "" }
        return "\n\n### Images\n" + lines.joined(separator: "\n")
    }

    private func selectedRecordingContextMarkdown(_ recording: Recording, query: String) -> String {
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
    private func hasTranscriptSource(_ rec: Recording) -> Bool {
        if let text = rec.transcriptText, !text.isEmpty { return true }
        guard let path = rec.txtPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Derive distinct speaker indices from the JSON sidecar via
    /// `ExportInputBuilder.build`. Returns [] for un-diarized recordings.
    private func speakerIndices(for recording: Recording) -> [Int] {
        let input = ExportInputBuilder.build(from: recording)
        var seen: Set<Int> = []
        for segment in input.segments {
            if let id = segment.speaker { seen.insert(id) }
        }
        return seen.sorted()
    }

    private func loadEnvelope() async {
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
    private func loadResolvedLabels() async {
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
    private func loadTranscript() {
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
    private func rebuildTranscriptSegments() {
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

    private static func buildDisplaySegments(
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

    private static func distanceFromSegment(_ point: Int, segment: SpeakerSegment) -> Int {
        if point < segment.startMs { return segment.startMs - point }
        if point >= segment.endMs  { return point - segment.endMs + 1 }
        return 0
    }

    /// Observe DB changes to the selected recording so the detail pane updates
    /// when the recording is renamed or its transcript is edited.
    private func observeRecording(recording: Recording) async {
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

// MARK: - AddPersonSheet

private struct AddPersonSheet: View {
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add person")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onAdd(trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Transcript display

struct TranscriptDisplaySegment: Identifiable {
    let id = UUID()
    let speaker: Int
    let speakerName: String
    let startSec: Int
    let text: String
}

// MARK: - Date grouping

private extension HarcWindowRootView {
    struct DateBucket {
        let label: String
        let recordings: [Recording]
    }

    struct NoteBucket {
        let label: String
        let notes: [Note]
    }

    static func noteBuckets(from notes: [Note]) -> [NoteBucket] {
        var grouped: [String: [Note]] = [:]
        var labels: [String] = []

        for note in notes {
            let label = note.folderPath?.isEmpty == false ? note.folderPath! : "Unfiled"
            if grouped[label] == nil {
                grouped[label] = []
                labels.append(label)
            }
            grouped[label, default: []].append(note)
        }

        labels.sort(by: noteBucketSort)
        return labels.compactMap { label in
            guard let notes = grouped[label] else { return nil }
            return NoteBucket(label: label, notes: notes)
        }
    }

    static func noteBucketSort(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "Unfiled" { return false }
        if rhs == "Unfiled" { return true }
        return lhs > rhs
    }

    /// Groups recordings (assumed already sorted newest-first by the VM) into
    /// human-readable date buckets: Today, Yesterday, This Week, then
    /// month-and-year labels for older entries.
    static func dateBuckets(from recordings: [Recording]) -> [DateBucket] {
        let cal = Calendar.current
        let now = Date()
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now),
              let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        else {
            return [DateBucket(label: "All", recordings: recordings)]
        }

        var today: [Recording] = []
        var yesterdayBucket: [Recording] = []
        var thisWeek: [Recording] = []
        var older: [String: [Recording]] = [:]
        var olderOrder: [String] = []

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"

        for rec in recordings {
            let date = rec.startedAt
            if cal.isDate(date, inSameDayAs: now) {
                today.append(rec)
            } else if cal.isDate(date, inSameDayAs: yesterday) {
                yesterdayBucket.append(rec)
            } else if date >= weekStart {
                thisWeek.append(rec)
            } else {
                let label = monthFormatter.string(from: date)
                if older[label] == nil {
                    older[label] = []
                    olderOrder.append(label)
                }
                older[label]!.append(rec)
            }
        }

        var buckets: [DateBucket] = []
        if !today.isEmpty { buckets.append(DateBucket(label: "Today", recordings: today)) }
        if !yesterdayBucket.isEmpty { buckets.append(DateBucket(label: "Yesterday", recordings: yesterdayBucket)) }
        if !thisWeek.isEmpty { buckets.append(DateBucket(label: "This Week", recordings: thisWeek)) }
        for label in olderOrder {
            if let recs = older[label], !recs.isEmpty {
                buckets.append(DateBucket(label: label, recordings: recs))
            }
        }
        return buckets
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Format duration between two dates as h:mm:ss or m:ss.
    static func formatDuration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        let h = seconds / 3600
        let m = (seconds / 60) % 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private extension String {
    var harcTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
