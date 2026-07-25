import SwiftUI
import Foundation
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
    let onEdit: (Recording) -> Void
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
    @State var peopleExpanded = false
    @State var recordingsExpanded = true
    @State var sidebarSectionOrder: [LibrarySidebarSection] = LibrarySidebarSection.defaultOrder
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
        onEdit: @escaping (Recording) -> Void,
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
        self.onEdit = onEdit
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
            importBanner
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
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: selection) { _, _ in
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

            // Trailing group: Import / Copy / Edit / Export / Delete + Inspector toggle.
            ToolbarItemGroup {
                if onImportFiles != nil {
                    Button {
                        presentImportPanel()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .help("Import an audio or video file and transcribe it")
                }

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
        inspectorPendingSuggestions.count
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

    // MARK: - Media import

    /// Compact status bar above the footer while an import runs (or just
    /// finished / failed). Hidden entirely when there is nothing to show.
    @ViewBuilder
    var importBanner: some View {
        if let job = importState.current {
            HStack(spacing: 8) {
                ProgressView(value: job.fraction)
                    .frame(width: 120)
                Text("\(job.phaseText) \u{201C}\(job.filename)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if importState.queuedCount > 0 {
                    Text("+\(importState.queuedCount) queued")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let onCancelImport {
                    Button("Cancel") { onCancelImport() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Stop this import — nothing is added to the library")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(.bar)
        } else if let error = importState.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Dismiss") { importState.dismissError() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(.bar)
        } else if let done = importState.lastCompletedFilename {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Imported \u{201C}\(done)\u{201D}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { importState.dismissCompleted() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }

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

    var calendarHeader: some View {
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

            // The live transcript replaces the empty detail pane, so it is
            // unreachable while an older recording is selected. This is the
            // way back to it without deselecting by hand.
            if recordingState.isRecording, selectedRecording != nil {
                Button {
                    selection = nil
                } label: {
                    Label("View live transcript", systemImage: "waveform")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("harc.library.capture.viewLiveTranscript")
            }

            if let recordingActionStatusText {
                Text(recordingActionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The sidebar is narrow, and this row lives inside a
            // `.listStyle(.sidebar)` List, which hands rows a single-line
            // treatment — so the sentence truncated mid-phrase to
            // "…configure the global hotkey in…", hiding the half that says
            // where to go. `lineLimit(nil)` is what overrides the List's
            // default; `fixedSize` alone did not.
            Text("Use the menu bar icon or configure the global hotkey in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        case people
        case recordings
    }

    func expansionGroup(for section: LibrarySidebarSection) -> SidebarExpansionGroup {
        switch section {
        case .recordings: return .recordings
        case .people: return .people
        }
    }

    func persistedExpansionBinding(_ group: SidebarExpansionGroup) -> Binding<Bool> {
        Binding(
            get: {
                switch group {
                case .people: return peopleExpanded
                case .recordings: return recordingsExpanded
                }
            },
            set: { newValue in
                switch group {
                case .people: peopleExpanded = newValue
                case .recordings: recordingsExpanded = newValue
                }
                persistNavigationSnapshot()
            }
        )
    }

    func restoreNavigationSnapshot() {
        let snapshot = LibraryNavigationStateStore.load()
        peopleExpanded = snapshot.peopleExpanded
        recordingsExpanded = snapshot.recordingsExpanded
        sidebarSectionOrder = LibrarySidebarSection.normalizedOrder(snapshot.sidebarSectionOrder)
        restoredSelection = snapshot.selection?.librarySelection
        if let restoredSelection {
            selection = restoredSelection
        }
    }

    func persistNavigationSnapshot() {
        LibraryNavigationStateStore.save(LibraryNavigationSnapshot(
            selection: selection.map(PersistedLibrarySelection.init),
            peopleExpanded: peopleExpanded,
            recordingsExpanded: recordingsExpanded,
            sidebarSectionOrder: sidebarSectionOrder
        ))
    }

    func restoreOrValidateSelection() {
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
                            onEdit(hit.recording)
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
        guard let recording = selectedRecording else { return }

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
