import SwiftUI
import HarcStore
import HarcExport
import HarcClient
import HarcCore
import AppKit

// MARK: - Notifications

public extension NSNotification.Name {
    /// Posted by AppDelegate when the user invokes "open library + focus search".
    /// `HarcWindowRootView` observes this to activate its search field.
    static let harcLibraryFocusSearch = NSNotification.Name("HarcLibraryFocusSearch")
}

// MARK: - LibrarySelection

/// Discriminated union for the sidebar selection. Either a recording (keyed
/// by wav path) or a Person row (keyed by DB id). Phase 6 wires the
/// person-detail pane; for now selecting a Person leaves the detail pane
/// in its empty state.
public enum LibrarySelection: Hashable {
    case recording(wavPath: String)
    case person(id: Int64)
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
    let onEdit: (Recording) -> Void
    let onExport: (Recording) -> Void
    let onDelete: (Recording) -> Void

    // MARK: View state

    /// Primary selection — `.recording(wavPath:)` for recordings, `.person(id:)` for People.
    @State private var selection: LibrarySelection?
    @State private var inspectorOpen: Bool = false
    @State private var showingAddPerson = false

    // Transcript text is loaded lazily on selection change to avoid
    // synchronous disk I/O in the view body.
    @State private var transcriptText: String = ""
    /// Set when the user picks Delete from a sidebar context menu — drives
    /// the destructive confirmation alert.
    @State private var pendingDeleteRecording: Recording? = nil
    /// When the .json sidecar is available, we render structured turns
    /// (timestamp + speaker + text) instead of the flat .txt blob.
    @State private var transcriptSegments: [TranscriptDisplaySegment] = []
    @State private var transcriptLoadError: String? = nil
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

    // MARK: Environment

    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var postProcessing: RecordingPostProcessingState

    // MARK: Init

    public init(
        libraryVM: LibraryViewModel,
        recordingState: RecordingState,
        bridge: HarcAppBridge,
        peopleVM: PeopleViewModel,
        store: RecordingStore,
        reIDService: SpeakerReIDService,
        onEdit: @escaping (Recording) -> Void,
        onExport: @escaping (Recording) -> Void,
        onDelete: @escaping (Recording) -> Void
    ) {
        self.libraryVM = libraryVM
        self.recordingState = recordingState
        self.bridge = bridge
        self.peopleVM = peopleVM
        self.store = store
        self.reIDService = reIDService
        self.onEdit = onEdit
        self.onExport = onExport
        self.onDelete = onDelete
    }

    // MARK: Body

    public var body: some View {
        VStack(spacing: 0) {
            split
            Divider()
            libraryFooter
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { libraryVM.start(); peopleVM.start() }
        .onDisappear { libraryVM.stop(); peopleVM.stop() }
        .onChange(of: selection) { _, _ in
            loadTranscript()
            Task { await loadEnvelope() }
            Task { await loadResolvedLabels() }
        }
        .alert(
            "Delete recording?",
            isPresented: Binding(
                get: { pendingDeleteRecording != nil },
                set: { if !$0 { pendingDeleteRecording = nil } }
            ),
            presenting: pendingDeleteRecording
        ) { rec in
            Button("Delete", role: .destructive) {
                let target = rec
                pendingDeleteRecording = nil
                Task {
                    do {
                        try await libraryVM.delete(recording: target)
                        if selection == .recording(wavPath: target.wavPath) { selection = nil }
                    } catch {
                        // Surface in console; LibraryViewModel logs to its own channel.
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
                    _ = try? await store.createPerson(displayName: name)
                    showingAddPerson = false
                }
            }
        }
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
            prompt: "Search transcripts"
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
                    if let rec = currentRecording { onExport(rec) }
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
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle inspector panel")
            }
        }
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
        let fm = FileManager.default
        var total: Int64 = 0
        for rec in libraryVM.recordings {
            if let attrs = try? fm.attributesOfItem(atPath: rec.wavPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: total)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
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
        }
        .navigationTitle("Library")
        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 480)
    }

    // MARK: - Calendar header

    private var calendarHeader: some View {
        VStack(spacing: 6) {
            MonthCalendarView(
                month: libraryVM.calendarMonth,
                selectedDay: selectedFilterDay,
                daysWithRecordings: libraryVM.daysWithRecordings,
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

    private var selectedFilterDay: Date? {
        if case .day(let d) = libraryVM.filter { return d }
        return nil
    }

    private func formatFilterDay(_ day: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        return fmt.string(from: day)
    }

    // Grouped recordings list: People first, then pinned, then by date-bucket.
    private var groupedList: some View {
        List(selection: $selection) {
            // People section — always first
            Section("People") {
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

            // Pinned section
            let pinned = libraryVM.recordings.filter(\.pinned)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { rec in
                        recordingLabel(rec)
                    }
                }
            }

            // Date-bucketed sections (unpinned only)
            let unpinned = libraryVM.recordings.filter { !$0.pinned }
            let buckets = Self.dateBuckets(from: unpinned)
            ForEach(buckets, id: \.label) { bucket in
                Section(bucket.label) {
                    ForEach(bucket.recordings) { rec in
                        recordingLabel(rec)
                    }
                }
            }
        }
    }

    // Search-results list: uses TranscriptHitRow for snippet highlighting.
    @ViewBuilder
    private var searchResultsList: some View {
        if libraryVM.hits.isEmpty {
            List {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No transcripts matched \u{201C}\(libraryVM.searchText)\u{201D}.")
                )
            }
        } else {
            List(selection: $selection) {
                ForEach(libraryVM.hits) { hit in
                    TranscriptHitRow(hit: hit) {
                        selection = .recording(wavPath: hit.recording.wavPath)
                    }
                    .tag(LibrarySelection.recording(wavPath: hit.recording.wavPath))
                    .contextMenu { contextMenu(for: hit.recording) }
                }
            }
        }
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
        .contextMenu { contextMenu(for: rec) }
    }

    @ViewBuilder
    private func contextMenu(for rec: Recording) -> some View {
        Button(rec.pinned ? "Unpin" : "Pin") {
            guard let id = rec.id else { return }
            Task { try? await libraryVM.togglePin(id: id, currentlyPinned: rec.pinned) }
        }
        Button("Open in Editor…") { onEdit(rec) }
        Button("Export…") { onExport(rec) }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
        }
        Button("Copy Transcript") { copyTranscript(rec) }
        Divider()
        Button("Delete", role: .destructive) {
            pendingDeleteRecording = rec
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
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
        case .recording, .none:
            if let recording = selectedRecording {
                detailContent(recording: recording)
                    .inspector(isPresented: $inspectorOpen) {
                        inspectorContent(recording: recording)
                    }
            } else {
                ContentUnavailableView(
                    "No Recording Selected",
                    systemImage: "waveform",
                    description: Text("Pick a recording from the sidebar.")
                )
            }
        }
    }

    private func detailContent(recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WaveformPlayerView(
                    envelope: detailEnvelope,
                    audioURL: URL(fileURLWithPath: recording.wavPath)
                )
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
                        Task { try? await store.clearSummaryStatus(id: id) }
                    }
                )
                .padding(.horizontal)

                // Transcript text
                transcriptBody
                    .padding(.horizontal)
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(recording.displayTitle)
        // Reload transcript when the selection's recording row changes in the DB.
        .task(id: recording.wavPath) {
            await observeRecording(recording: recording)
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
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
                        Text(seg.text)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if transcriptText.isEmpty {
            Text("No transcript available.")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(transcriptText)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    Task { try? await store.updateSpeakerNames(id: id, names: newNames) }
                },
                suggestionsProvider: nil,
                pendingSuggestions: inspectorPendingSuggestions,
                personNamesByID: allPeopleByID,
                onConfirmSuggestion: { s in
                    Task {
                        try? await store.confirmSuggestion(
                            personID: s.personID,
                            recordingID: s.recordingID,
                            speakerIndex: s.speakerIndex
                        )
                        if let id = recording.id {
                            inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
                        }
                        await loadResolvedLabels()
                    }
                },
                onDismissSuggestion: { s in
                    Task {
                        try? await store.dismissSuggestion(
                            personID: s.personID,
                            recordingID: s.recordingID,
                            speakerIndex: s.speakerIndex
                        )
                        if let id = recording.id {
                            inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
                        }
                    }
                },
                recordingID: recording.id,
                allPeople: allPeople,
                onLinkPerson: { personID, speakerIndex in
                    guard let rid = recording.id else { return }
                    Task {
                        try? await store.linkSpeaker(personID: personID, recordingID: rid, speakerIndex: speakerIndex)
                        await loadResolvedLabels()
                    }
                },
                onCreatePerson: { name, speakerIndex in
                    guard let rid = recording.id else { return }
                    Task {
                        if let pid = try? await store.createPerson(displayName: name, matchThreshold: nil) {
                            try? await store.linkSpeaker(personID: pid, recordingID: rid, speakerIndex: speakerIndex)
                            let people = (try? await store.fetchPeople()) ?? []
                            allPeople = people
                            allPeopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
                            await loadResolvedLabels()
                        }
                    }
                },
                onUnlinkPerson: { speakerIndex in
                    guard let rid = recording.id else { return }
                    Task {
                        try? await store.unlinkSpeaker(recordingID: rid, speakerIndex: speakerIndex)
                        await loadResolvedLabels()
                    }
                }
            )

            FileInspectorSection(recording: recording)
        }
        .formStyle(.grouped)
        .background(.thinMaterial)
        .navigationTitle("Inspector")
        .task(id: recording.id) {
            let people = (try? await store.fetchPeople()) ?? []
            allPeople = people
            allPeopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.displayName) })
            if let id = recording.id {
                inspectorPendingSuggestions = (try? await store.fetchPendingSuggestionsForRecording(id)) ?? []
            } else {
                inspectorPendingSuggestions = []
            }
        }
    }

    // MARK: - Helpers

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
