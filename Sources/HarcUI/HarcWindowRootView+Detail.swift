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

// Detail-pane view code for `HarcWindowRootView`, split out of the main
// view file. Same type, same stored state — relocated into an extension to
// keep each file focused. Members it shares with the rest of the view are
// `internal` rather than `private`.

extension HarcWindowRootView {
    // MARK: - Detail

    @ViewBuilder
    var detail: some View {
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
    var detailBody: some View {
        switch mode {
        case .library:
            libraryDetail
        case .wiki:
            wikiDetail
        case .review:
            reviewDetail
        }
    }

    func mutationFailureBanner(_ failure: LibraryMutationFailure) -> some View {
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
    var libraryDetail: some View {
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

    var wikiDetail: some View {
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

    var reviewDetail: some View {
        let selected = selectedReviewProposalID.flatMap { id in reviewProposals.first { $0.id == id } }
        let grouping = ReviewProposalGrouping.make(from: reviewProposals)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Review", systemImage: "checklist")
                        .font(.title.weight(.semibold))
                    Spacer()
                    Button {
                        Task { await generateReviewFromLibrary() }
                    } label: {
                        Label("Generate Review", systemImage: "sparkles")
                    }
                    .disabled(libraryVM.recordings.isEmpty && notes.isEmpty)

                    Button {
                        Task { await loadReviewProposals() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                if let reviewGenerationStatus {
                    Text(reviewGenerationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let reviewLoadError {
                    Label(reviewLoadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.red)
                } else if let selected {
                    reviewQueueSummary(grouping)
                    reviewProposalView(selected)
                } else if reviewProposals.isEmpty {
                    reviewEmptyState
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    reviewQueueSummary(grouping)
                    reviewProposalList(grouping)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Review")
    }

    func projectDetail(name: String) -> some View {
        let relatedNotes = notesForProject(name)
        let relatedRecordings = recordingsForProject(name)

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(name, systemImage: "folder")
                        .font(.title.weight(.semibold))
                    Text(projectSubtitle(noteCount: relatedNotes.count, recordingCount: relatedRecordings.count))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            createNote(forProject: name)
                        } label: {
                            Label("New Note", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            copyProjectMention(name)
                        } label: {
                            Label("Copy Mention", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
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

    func projectNoteRow(_ note: Note) -> some View {
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

    func projectRecordingRow(_ recording: Recording) -> some View {
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

    func wikiPageRow(_ page: WikiPage) -> some View {
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

    func wikiPageView(_ page: WikiPage) -> some View {
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
                    copyWikiPageContext(page)
                } label: {
                    Label("Copy Context", systemImage: "doc.on.doc")
                }
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

    func copyWikiPageContext(_ page: WikiPage) {
        let pack = ContextPackBuilder.build(wikiPage: page)
        let markdown = ContextPackMarkdownRenderer.render(pack)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    func wikiEmptyTitle(for section: WikiSection) -> String {
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

    func wikiEmptyDescription(for section: WikiSection) -> String {
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

    func wikiEmptyState(for section: WikiSection) -> some View {
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
                Button("Generate Review") { Task { await generateReviewFromLibrary() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(libraryVM.recordings.isEmpty && notes.isEmpty)
            }
        }
    }

    var reviewEmptyState: some View {
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
                ("Pending proposals", "\(ReviewProposalGrouping.make(from: reviewProposals).pendingCount)", false),
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

    func prerequisiteGrid(_ rows: [(String, String, Bool)]) -> some View {
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

    func reviewQueueSummary(_ grouping: ReviewProposalGrouping) -> some View {
        let columns = [GridItem(.adaptive(minimum: 116), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            reviewMetric("Pending", value: grouping.pendingCount, icon: "tray.full", color: .accentColor)
            reviewMetric("Approved", value: grouping.approvedCount, icon: "checkmark.circle", color: .green)
            reviewMetric("Needs Attention", value: grouping.failedCount, icon: "exclamationmark.triangle", color: .red)
            reviewMetric("Dismissed", value: grouping.dismissedCount, icon: "xmark.circle", color: .secondary)
        }
    }

    func reviewMetric(_ title: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    func reviewBucket(_ bucket: ReviewProposalBucket) -> some View {
        Text("\(bucket.title) (\(bucket.count))")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        ForEach(bucket.proposals) { proposal in
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .lineLimit(1)
                    Text(reviewSidebarSubtitle(for: proposal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: reviewIcon(for: proposal))
                    .foregroundStyle(reviewColor(for: proposal))
            }
            .tag(Optional(proposal.id))
        }
    }

    func reviewProposalList(_ grouping: ReviewProposalGrouping) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(grouping.buckets) { bucket in
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(bucket.title) (\(bucket.count))", systemImage: bucket.systemImage)
                        .font(.headline)
                    ForEach(bucket.proposals) { proposal in
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
    }

    func reviewProposalRow(_ proposal: WikiReviewProposal) -> some View {
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
                HStack(spacing: 6) {
                    reviewPill(proposal.targetSection.title, icon: proposal.targetSection.systemImage)
                    reviewPill("Impact \(proposal.impact.title)", icon: "bolt")
                    reviewPill("Confidence \(proposal.confidence.title)", icon: "gauge")
                }
            }
            Spacer()
            Text(proposal.status.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func reviewProposalView(_ proposal: WikiReviewProposal) -> some View {
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
                    copyReviewProposalContext(proposal, markdown: currentReviewMarkdown(for: proposal))
                } label: {
                    Label("Copy Context", systemImage: "doc.on.doc")
                }
                .disabled(currentReviewMarkdown(for: proposal).isEmpty)

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

            HStack(spacing: 6) {
                reviewPill("Impact \(proposal.impact.title)", icon: "bolt")
                reviewPill("Confidence \(proposal.confidence.title)", icon: "gauge")
                reviewPill(proposal.status.rawValue.capitalized, icon: reviewIcon(for: proposal))
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Target")
                    .font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Section")
                            .foregroundStyle(.secondary)
                        Label(proposal.targetSection.title, systemImage: proposal.targetSection.systemImage)
                    }
                    GridRow {
                        Text("Page")
                            .foregroundStyle(.secondary)
                        Text(proposal.targetTitle)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Proposed Change")
                    .font(.headline)
                Text(proposal.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !proposal.renderedCitations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Evidence")
                        .font(.headline)
                    ForEach(proposal.renderedCitations, id: \.self) { citation in
                        Text(citation)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Markdown")
                        .font(.headline)
                    if reviewMarkdownIsDirty(proposal) {
                        Text("Unsaved edits")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }
                    Spacer()
                    Button {
                        Task { await saveReviewMarkdownDraft(for: proposal) }
                    } label: {
                        Label("Save Edits", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(
                        !reviewMarkdownIsDirty(proposal)
                        || busy
                        || proposal.status == .approved
                        || proposal.status == .dismissed
                    )

                    Button {
                        reviewMarkdownDrafts[proposal.id] = proposal.proposedMarkdown
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!reviewMarkdownIsDirty(proposal) || busy)
                }

                TextEditor(text: reviewMarkdownBinding(for: proposal))
                    .font(.system(.body, design: .monospaced))
                    .lineSpacing(4)
                    .frame(minHeight: 280)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .disabled(proposal.status == .approved || proposal.status == .dismissed)
            }
        }
    }

    func reviewPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    func reviewSidebarSubtitle(for proposal: WikiReviewProposal) -> String {
        "\(proposal.targetSection.title) - \(proposal.status.rawValue.capitalized)"
    }

    func copyReviewProposalContext(_ proposal: WikiReviewProposal, markdown: String) {
        var sections: [String] = [
            "# Review Proposal: \(proposal.title)",
            "Status: \(proposal.status.rawValue)",
            "Impact: \(proposal.impact.rawValue)",
            "Confidence: \(proposal.confidence.rawValue)",
            "Target: \(proposal.targetSection.title) / \(proposal.targetTitle)",
            "",
            "## Summary",
            proposal.summary,
            "",
            "## Proposed Markdown",
            markdown,
        ]
        if !proposal.renderedCitations.isEmpty {
            sections.append("")
            sections.append("## Evidence")
            sections.append(proposal.renderedCitations.map { "- \($0)" }.joined(separator: "\n"))
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sections.joined(separator: "\n"), forType: .string)
        reviewActionStatus[proposal.id] = "Copied proposal context."
    }

    func currentReviewMarkdown(for proposal: WikiReviewProposal) -> String {
        reviewMarkdownDrafts[proposal.id] ?? proposal.proposedMarkdown
    }

    func reviewMarkdownIsDirty(_ proposal: WikiReviewProposal) -> Bool {
        currentReviewMarkdown(for: proposal) != proposal.proposedMarkdown
    }

    func reviewMarkdownBinding(for proposal: WikiReviewProposal) -> Binding<String> {
        Binding(
            get: { currentReviewMarkdown(for: proposal) },
            set: { reviewMarkdownDrafts[proposal.id] = $0 }
        )
    }

    func reviewIcon(for proposal: WikiReviewProposal) -> String {
        switch proposal.status {
        case .pending: return "circle"
        case .edited: return "pencil.circle"
        case .approved: return "checkmark.circle.fill"
        case .dismissed: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    func reviewColor(for proposal: WikiReviewProposal) -> Color {
        switch proposal.status {
        case .pending, .edited: return Color.accentColor
        case .approved: return Color.green
        case .dismissed: return Color.secondary
        case .failed: return Color.red
        }
    }

    func reviewActionStatusIcon(_ status: String) -> String {
        status.localizedCaseInsensitiveContains("failed")
            ? "exclamationmark.triangle"
            : "info.circle"
    }

    func noteDetail(note: Note) -> some View {
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

                HStack(spacing: 8) {
                    Picker("Writing Mode", selection: Binding(
                        get: { noteEditorMode == .read ? noteWritingMode : noteEditorMode },
                        set: { mode in
                            guard mode != .read else { return }
                            noteWritingMode = mode
                            noteEditorMode = mode
                        }
                    )) {
                        ForEach(Self.noteWritingModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .accessibilityIdentifier("harc.note.writingModePicker")

                    Button {
                        if noteEditorMode == .read {
                            noteEditorMode = noteWritingMode
                        } else {
                            if noteEditorMode != .read {
                                noteWritingMode = noteEditorMode
                            }
                            noteEditorMode = .read
                        }
                    } label: {
                        Label("Preview", systemImage: noteEditorMode == .read ? "eye.fill" : "eye")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("harc.note.previewToggle")
                }

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
                    guard !bridge.recordingStopInFlight else { return }
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
                        systemImage: bridge.recordingStopInFlight ? "hourglass" : recordingToolbarState.systemImage
                    )
                }
                .tint(recordingToolbarState == .recordingIntoThisNote ? HarcBrand.live : nil)
                .disabled(bridge.recordingStopInFlight)

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
    func noteEditorSurface(note: Note) -> some View {
        switch noteEditorMode {
        case .source:
            NoteMarkdownWebView(text: noteBodyBinding, mode: .source,
               linkTargets: noteLinkTargets(for: note),
               mentionTargets: noteMentionTargets(),
               attachmentBaseURL: note.fileURL.deletingLastPathComponent(),
               showsFormattingRibbon: prefs.markdownFormattingRibbonEnabled,
               onPasteImage: { image in
                   try await pasteImage(image, into: note.id)
               })
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("Raw Markdown note editor")
            .accessibilityIdentifier("harc.note.markdownTextEditor")

        case .live:
            NoteMarkdownWebView(text: noteBodyBinding, mode: .live,
               linkTargets: noteLinkTargets(for: note),
               mentionTargets: noteMentionTargets(),
               attachmentBaseURL: note.fileURL.deletingLastPathComponent(),
               showsFormattingRibbon: prefs.markdownFormattingRibbonEnabled,
               onPasteImage: { image in
                   try await pasteImage(image, into: note.id)
               })
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("Live Markdown note editor")
            .accessibilityIdentifier("harc.note.liveMarkdownEditor")

        case .read:
            NoteMarkdownWebView(text: noteBodyBinding, mode: .read,
               linkTargets: noteLinkTargets(for: note),
               mentionTargets: noteMentionTargets(),
               attachmentBaseURL: note.fileURL.deletingLastPathComponent(),
               showsFormattingRibbon: prefs.markdownFormattingRibbonEnabled)
            .accessibilityLabel("Markdown note preview")
            .accessibilityIdentifier("harc.note.markdownPreview")
        }
    }

    var noteBodyBinding: Binding<String> {
        Binding(
            get: { currentNoteBodyDraft },
            set: { updateNoteBodyDraftFromEditor($0) }
        )
    }

    var currentNoteBodyDraft: String {
        noteDraftSession.body
    }

    func setNoteBodyDraft(_ body: String) {
        noteBodyDraft = body
        noteDraftSession.load(body: body)
    }

    func updateNoteBodyDraftFromEditor(_ body: String) {
        guard body != noteDraftSession.body else { return }
        noteDraftSession.edit(body: body)
        markNoteEdited(advanceGeneration: false)
    }

    func noteTextEditorSurface(font: Font) -> some View {
        ZStack(alignment: .topLeading) {
            if currentNoteBodyDraft.isEmpty {
                Text("Start writing in Markdown...")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .allowsHitTesting(false)
            }

            TextEditor(text: Binding(
                get: { currentNoteBodyDraft },
                set: { updateNoteBodyDraftFromEditor($0) }
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

    func noteRecordingLinkBanner(_ feedback: NoteRecordingLinkFeedback) -> some View {
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

    func noteRecordingConflictBanner(_ conflict: NoteRecordingConflict) -> some View {
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

    func noteSaveConflictBanner(_ conflict: NoteSaveConflict) -> some View {
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

    func noteLinksSection(note: Note) -> some View {
        let links = resolvedWikilinks(in: currentNoteBodyDraft, currentNoteID: note.id)
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

    func detailContent(recording: Recording) -> some View {
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

    func inspectorSummaryChips(for recording: Recording) -> some View {
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

    func inspectorChip(title: String, icon: String, tint: Color) -> some View {
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
    func transcriptBody(proxy: ScrollViewProxy) -> some View {
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

    func transcriptFindBar(proxy: ScrollViewProxy) -> some View {
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

    func transcriptKeyboardShortcuts(proxy: ScrollViewProxy) -> some View {
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

    var transcriptSearchQuery: String {
        transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var transcriptSearchMatches: [TranscriptSearchMatch] {
        let query = transcriptSearchQuery
        guard !query.isEmpty else { return [] }

        if !transcriptSegments.isEmpty {
            return transcriptSegments.flatMap { segment in
                TranscriptFind.matches(in: segment.text, query: query, segmentID: segment.id)
            }
        }

        return TranscriptFind.matches(in: transcriptText, query: query)
    }

    var transcriptSearchStatus: String {
        let matches = transcriptSearchMatches
        guard !transcriptSearchQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return "0/0" }
        return "\(min(transcriptSearchIndex + 1, matches.count))/\(matches.count)"
    }

    var activeTranscriptMatchSegmentID: UUID? {
        activeTranscriptMatch?.segmentID
    }

    var activeTranscriptMatch: TranscriptSearchMatch? {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(transcriptSearchIndex, matches.count - 1)]
    }

    func activeTranscriptMatch(for segmentID: UUID) -> TranscriptSearchMatch? {
        guard let match = activeTranscriptMatch, match.segmentID == segmentID else { return nil }
        return match
    }

    func jumpToNextTranscriptMatch(proxy: ScrollViewProxy) {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + 1) % matches.count
        scrollToTranscriptMatch(matches[transcriptSearchIndex], proxy: proxy)
    }

    func jumpToPreviousTranscriptMatch(proxy: ScrollViewProxy) {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + matches.count - 1) % matches.count
        scrollToTranscriptMatch(matches[transcriptSearchIndex], proxy: proxy)
    }

    func scrollToTranscriptMatch(_ match: TranscriptSearchMatch, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if let segmentID = match.segmentID {
                proxy.scrollTo(segmentID, anchor: .center)
            } else {
                proxy.scrollTo("flat-transcript", anchor: .center)
            }
        }
    }

    func jumpToNextSpeakerBoundary(proxy: ScrollViewProxy) {
        guard let id = nextSpeakerBoundaryID(forward: true) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    func jumpToPreviousSpeakerBoundary(proxy: ScrollViewProxy) {
        guard let id = nextSpeakerBoundaryID(forward: false) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    func nextSpeakerBoundaryID(forward: Bool) -> UUID? {
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

    func highlightedTranscriptText(_ text: String, activeMatch: TranscriptSearchMatch?) -> AttributedString {
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

    func formatTimestamp(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds / 60) % 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

}
