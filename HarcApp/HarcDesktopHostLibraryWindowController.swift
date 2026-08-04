import AppKit
import HarcDomain
import Observation
import SwiftUI

@MainActor
final class HarcDesktopHostLibraryWindowController: NSWindowController {
    init(coordinator: HarcMobileLibraryCoordinator) {
        let root = HarcDesktopHostLibraryView(coordinator: coordinator)
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: root)
        )
        window.title = "Harc — Host Library"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.setContentSize(NSSize(width: 1_120, height: 720))
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }
}

private struct HarcDesktopLibraryRowModel: Identifiable {
    let summary: LibraryRecordingSummary
    let snippets: [String]

    var id: CanonicalRecordingID { summary.canonicalID }
}

private struct HarcDesktopHostLibraryView: View {
    @Bindable var coordinator: HarcMobileLibraryCoordinator
    @State private var selection: CanonicalRecordingID?
    @State private var searchText = ""
    @State private var cacheMessage: String?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                statusBanner
                if rows.isEmpty {
                    emptyView
                } else {
                    List(rows, selection: $selection) { row in
                        HarcDesktopHostLibraryRow(row: row)
                            .tag(row.id)
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let summary = selectedSummary {
                HarcDesktopHostRecordingDetailView(
                    coordinator: coordinator,
                    summary: summary
                )
                .id(summary.canonicalID)
            } else {
                ContentUnavailableView(
                    "Host Library",
                    systemImage: "macmini",
                    description: Text(
                        "Select a Host recording. Your existing local recordings remain in On This Mac."
                    )
                )
            }
        }
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: "Titles, tags, and transcripts"
        )
        .task(id: searchText) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                await coordinator.search(searchText)
            } catch {}
        }
        .onAppear {
            coordinator.refresh()
            selectFirstIfNeeded()
        }
        .onChange(of: rows.map(\.id)) { _, _ in
            selectFirstIfNeeded()
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh Host Library", systemImage: "arrow.clockwise") {
                    coordinator.refresh()
                }
                .disabled(coordinator.isRefreshing)
                Menu("Library Cache", systemImage: "externaldrive") {
                    Button("Clear Downloaded Audio") {
                        do {
                            try coordinator.clearDownloadedAudio()
                            cacheMessage = "Downloaded Host audio was cleared."
                        } catch {
                            cacheMessage = error.localizedDescription
                        }
                    }
                    Button("Rebuild Host Library Cache") {
                        do {
                            try coordinator.resetLibraryCache()
                            selection = nil
                            cacheMessage = "Rebuilding the Host Library cache."
                        } catch {
                            cacheMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private var rows: [HarcDesktopLibraryRowModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return coordinator.recordings.map {
                HarcDesktopLibraryRowModel(summary: $0, snippets: [])
            }
        }
        return coordinator.searchResults.map {
            HarcDesktopLibraryRowModel(
                summary: $0.recording,
                snippets: $0.snippets
            )
        }
    }

    private var selectedSummary: LibraryRecordingSummary? {
        guard let selection else { return nil }
        return rows.first(where: { $0.id == selection })?.summary
    }

    @ViewBuilder
    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch coordinator.state {
            case .loadingCache:
                Label("Opening protected Host Library cache…", systemImage: "externaldrive")
            case .unpaired:
                Label("Pair this Mac with a Host to load its Library.", systemImage: "link.badge.plus")
            case .accessNotGranted:
                Label("This device grant does not include Host Library access.", systemImage: "lock")
                    .foregroundStyle(.orange)
            case .refreshing:
                Label("Refreshing from Host…", systemImage: "arrow.triangle.2.circlepath")
            case .ready(let updated):
                if let updated {
                    Label(
                        "Host Library updated \(updated.formatted(.relative(presentation: .named)))",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            case .offline(let message):
                Label(message, systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if coordinator.pendingMutationCount > 0 {
                Text(
                    "\(coordinator.pendingMutationCount) signed edit(s) are waiting for Host."
                )
                .foregroundStyle(.secondary)
            }
            if !coordinator.conflicts.isEmpty {
                Text("\(coordinator.conflicts.count) edit conflict(s) need review.")
                    .foregroundStyle(.orange)
            }
            if let cacheMessage {
                Text(cacheMessage).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var emptyView: some View {
        if coordinator.isRefreshing || coordinator.isSearching {
            Spacer()
            ProgressView(
                coordinator.isSearching ? "Searching Host…" : "Refreshing Host Library…"
            )
            Spacer()
        } else if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView(
                "No Host recordings",
                systemImage: "rectangle.stack",
                description: Text("The protected Host Library cache is empty.")
            )
        }
    }

    private func selectFirstIfNeeded() {
        if let selection, rows.contains(where: { $0.id == selection }) {
            return
        }
        selection = rows.first?.id
    }
}

private struct HarcDesktopHostLibraryRow: View {
    let row: HarcDesktopLibraryRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(
                    row.summary.title
                        ?? row.summary.suggestedTitle
                        ?? "Untitled Recording"
                )
                .font(.headline)
                .lineLimit(2)
                if row.summary.pinned {
                    Image(systemName: "pin.fill").foregroundStyle(.tint)
                }
            }
            Text(
                row.summary.startedAt,
                format: .dateTime.month().day().year().hour().minute()
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(row.summary.processing.state.rawValue)
                if !row.summary.tags.isEmpty {
                    Text(row.summary.tags.prefix(3).joined(separator: " · "))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let snippet = row.snippets.first, !snippet.isEmpty {
                Text(
                    snippet.replacingOccurrences(of: "<mark>", with: "")
                        .replacingOccurrences(of: "</mark>", with: "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct HarcDesktopHostRecordingDetailView: View {
    @Bindable var coordinator: HarcMobileLibraryCoordinator
    let summary: LibraryRecordingSummary

    @State private var detail: LibraryRecordingDetail?
    @State private var errorMessage: String?
    @State private var titleDraft = ""
    @State private var tagsDraft = ""
    @State private var notesDraft = ""
    @State private var mutationMessage: String?
    @State private var isSavingMetadata = false
    @State private var audioController: HarcMobileRecordingAudioController

    init(
        coordinator: HarcMobileLibraryCoordinator,
        summary: LibraryRecordingSummary
    ) {
        self.coordinator = coordinator
        self.summary = summary
        _audioController = State(
            initialValue: HarcMobileRecordingAudioController(
                coordinator: coordinator,
                summary: summary
            )
        )
    }

    var body: some View {
        Group {
            if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(detail)
                        metadataEditor(detail)
                        conflicts
                        textSection("Transcript", detail.transcriptText)
                        textSection("Summary", detail.summaryMarkdown)
                        textSection("Action Items", detail.actionItemsMarkdown)
                        textSection("Notes", detail.notesMarkdown)
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Host detail unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Loading from Host…")
            }
        }
        .navigationTitle(summary.title ?? summary.suggestedTitle ?? "Recording")
        .task(id: summary.canonicalID) { await loadDetail() }
        .onDisappear { audioController.stopAndRelease() }
    }

    private func header(_ detail: LibraryRecordingDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Processing", value: detail.summary.processing.state.rawValue)
                LabeledContent("Projection", value: detail.summary.projection.state.rawValue)
                LabeledContent("Revision", value: String(detail.summary.revision.rawValue))
                if detail.summary.canonicalAudio.availability == .available {
                    Button {
                        Task { await audioController.playOrPause() }
                    } label: {
                        audioPlaybackLabel
                    }
                    .disabled(audioController.state == .downloading)
                }
                if case .failed(let message) = audioController.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Host Recording")
        }
    }

    private func metadataEditor(_ detail: LibraryRecordingDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: $titleDraft)
                HStack {
                    Button("Save Title") {
                        let trimmed = titleDraft.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        submitMetadata(.setTitle(trimmed.isEmpty ? nil : titleDraft))
                    }
                    Spacer()
                    Button(detail.summary.pinned ? "Unpin" : "Pin") {
                        submitMetadata(.setPinned(!detail.summary.pinned))
                    }
                }
                TextField("Tags separated by commas", text: $tagsDraft)
                Button("Replace Tags") {
                    submitMetadata(
                        .replaceTags(
                            tagsDraft.split(separator: ",").map(String.init)
                        )
                    )
                }
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notesDraft)
                    .font(.body)
                    .frame(minHeight: 100)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                Button("Save Notes") {
                    let trimmed = notesDraft.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    submitMetadata(
                        .setNotesMarkdown(trimmed.isEmpty ? nil : notesDraft)
                    )
                }
                .disabled(isSavingMetadata)
                if isSavingMetadata { ProgressView("Signing and sending…") }
                if let mutationMessage {
                    Text(mutationMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Edit on Host")
        }
    }

    @ViewBuilder
    private var conflicts: some View {
        let visible = coordinator.conflicts.filter {
            $0.canonicalRecordingID == summary.canonicalID
        }
        if !visible.isEmpty {
            GroupBox("Edit Conflicts") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visible, id: \.conflictID) { conflict in
                        Text(
                            "Host revision \(conflict.currentRevision.rawValue) replaced expected revision \(conflict.expectedRevision.rawValue)."
                        )
                        Button("Use Host Value") {
                            do {
                                try coordinator.acceptHostValue(for: conflict)
                                mutationMessage = "Conflict resolved with the Host value."
                                Task { await loadDetail() }
                            } catch {
                                mutationMessage = error.localizedDescription
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func textSection(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            GroupBox(title) {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func submitMetadata(_ mutation: HarcMobileMetadataMutation) {
        guard let current = detail?.summary, !isSavingMetadata else { return }
        isSavingMetadata = true
        mutationMessage = nil
        Task {
            defer { isSavingMetadata = false }
            do {
                let outcome = try await coordinator.submitMetadataMutation(
                    summary: current,
                    mutation: mutation
                )
                switch outcome {
                case .applied:
                    mutationMessage = "Saved on Host."
                    await loadDetail()
                case .queuedOffline:
                    mutationMessage =
                        "The signed edit is protected locally and will retry when Host returns."
                case .conflict:
                    mutationMessage = "Host has a newer revision. Review the conflict below."
                }
            } catch {
                mutationMessage = error.localizedDescription
            }
        }
    }

    private func loadDetail() async {
        do {
            let loaded = try await coordinator.recordingDetail(
                canonicalID: summary.canonicalID
            )
            detail = loaded
            titleDraft = loaded.summary.title ?? ""
            tagsDraft = loaded.summary.tags.joined(separator: ", ")
            notesDraft = loaded.notesMarkdown ?? ""
            if loaded.summary.revision != summary.revision {
                audioController.stopAndRelease()
                audioController = HarcMobileRecordingAudioController(
                    coordinator: coordinator,
                    summary: loaded.summary
                )
            }
            errorMessage = nil
        } catch {
            if detail == nil { errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder
    private var audioPlaybackLabel: some View {
        switch audioController.state {
        case .idle:
            Label("Play Verified Host Audio", systemImage: "play.fill")
        case .downloading:
            HStack { ProgressView(); Text("Downloading verified audio…") }
        case .playing:
            Label("Pause", systemImage: "pause.fill")
        case .paused:
            Label("Resume", systemImage: "play.fill")
        case .failed:
            Label("Try Audio Again", systemImage: "arrow.clockwise")
        }
    }
}
