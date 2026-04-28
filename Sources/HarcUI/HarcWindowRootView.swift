import SwiftUI
import HarcStore
import HarcExport

// MARK: - HarcWindowRootView

/// Main window root view (Task 3.2). Hosts a `NavigationSplitView` with a
/// recording-list sidebar (grouped by date / pinned), a transcript detail pane,
/// and an inspector panel showing speaker and file metadata.
///
/// Toolbar actions (Edit, Export, Delete, recording pill) are wired in Task 3.3.
/// This view is hosted by `HarcWindowController` (renamed in Task 3.4).
/// The legacy `LibraryWindowRootView` and `TranscriptionDetailView` are removed
/// in Task 3.5.
public struct HarcWindowRootView: View {
    @ObservedObject var libraryVM: LibraryViewModel

    let store: RecordingStore
    let reIDService: SpeakerReIDService

    // MARK: View state

    /// Primary selection — keyed on `wavPath` (String), matching how the
    /// existing VMs index recordings. This matches the selection approach used
    /// by `LibraryWindowRootView`.
    @State private var selection: String?
    @State private var inspectorOpen: Bool = false

    // Transcript text is loaded lazily on selection change to avoid
    // synchronous disk I/O in the view body.
    @State private var transcriptText: String = ""
    @State private var transcriptLoadError: String? = nil

    // MARK: Environment

    @EnvironmentObject private var prefs: HarcPreferences
    @EnvironmentObject private var postProcessing: RecordingPostProcessingState

    // MARK: Init

    public init(
        libraryVM: LibraryViewModel,
        store: RecordingStore,
        reIDService: SpeakerReIDService
    ) {
        self.libraryVM = libraryVM
        self.store = store
        self.reIDService = reIDService
    }

    // MARK: Body

    public var body: some View {
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
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { libraryVM.start() }
        .onDisappear { libraryVM.stop() }
        // Reload transcript text whenever the selected recording changes.
        .onChange(of: selection) { _, _ in loadTranscript() }
        // Inspector toggle placeholder — Task 3.3 moves this into the proper
        // toolbar alongside Edit/Export/Delete/recording-pill.
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    inspectorOpen.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Toggle inspector panel")
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        Group {
            if libraryVM.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groupedList
            } else {
                searchResultsList
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
    }

    // Grouped recordings list: pinned first, then by date-bucket.
    private var groupedList: some View {
        List(selection: $selection) {
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
                        selection = hit.recording.wavPath
                    }
                    .tag(hit.recording.wavPath)
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
        .tag(rec.wavPath)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
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

    private func detailContent(recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary card — requires SummarizationQueueStore and
                // ModelManagerStore injected as environment objects by the
                // window controller (same as TranscriptionDetailView).
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

    // MARK: - Inspector

    private func inspectorContent(recording: Recording) -> some View {
        Form {
            SpeakerInspectorSection(
                // Derive speaker indices from the JSON sidecar the same way
                // TranscriptionDetailView does via ExportInputBuilder.
                // TODO(Task 3.3/3.4): wire suggestions via reIDService.
                speakerIndices: speakerIndices(for: recording),
                initialNames: recording.speakerNames,
                onCommit: { newNames in
                    guard let id = recording.id else { return }
                    Task { try? await store.updateSpeakerNames(id: id, names: newNames) }
                },
                suggestionsProvider: nil
            )

            FileInspectorSection(recording: recording)
        }
        .formStyle(.grouped)
        .background(.thinMaterial)
        .navigationTitle("Inspector")
    }

    // MARK: - Helpers

    /// Resolved recording for the current selection path.
    private var selectedRecording: Recording? {
        guard let path = selection else { return nil }
        // Check search hits first (they carry the same Recording), then the
        // main recordings list.
        if let hit = libraryVM.hits.first(where: { $0.recording.wavPath == path }) {
            return hit.recording
        }
        return libraryVM.recordings.first { $0.wavPath == path }
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

    /// Loads `transcriptText` from cache or disk. Called on selection change.
    private func loadTranscript() {
        transcriptLoadError = nil
        transcriptText = ""
        guard let recording = selectedRecording else { return }

        if let cached = recording.transcriptText, !cached.isEmpty {
            transcriptText = cached
            return
        }
        guard let txtPath = recording.txtPath else {
            transcriptLoadError = "No transcript file — recording may not have been transcribed."
            return
        }
        do {
            transcriptText = try String(contentsOf: URL(fileURLWithPath: txtPath), encoding: .utf8)
        } catch {
            transcriptLoadError = "Could not load transcript: \(error.localizedDescription)"
        }
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
