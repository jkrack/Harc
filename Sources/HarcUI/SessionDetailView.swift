import SwiftUI
import HarcStore

/// Detail pane for a virtual day session: editable title, the combined
/// summary, and the member recordings (each clicks through to its own
/// detail pane). Deliberately no merged waveform or player — audio belongs
/// to the members.
struct SessionDetailView: View {
    let sessionID: Int64
    let store: RecordingStore
    let onSelectRecording: (Recording) -> Void
    /// Nil hides the Summarize affordance (previews/tests).
    let onSummarize: ((Int64) -> Void)?
    let onDissolve: (Session) -> Void

    @State private var session: Session?
    @State private var members: [Recording] = []
    @State private var titleDraft = ""
    /// The title as last loaded from the DB — lets a fresh emission refresh
    /// the draft only when the user hasn't diverged from it (typing must not
    /// be clobbered by an unrelated summary landing).
    @State private var lastLoadedTitle: String?
    @State private var renameError: String?

    var body: some View {
        Group {
            if let session {
                content(session: session)
            } else {
                ContentUnavailableView(
                    "Session Not Found",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("This session may have been dissolved.")
                )
            }
        }
        .task(id: sessionID) { await observe() }
    }

    private func content(session: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcSpacing.lg) {
                titleRow(session: session)

                summaryCard(session: session)

                NotesCardView(
                    itemID: sessionID,
                    notes: session.notesMarkdown,
                    onSave: { [store] text in
                        try await store.updateSessionNotes(id: sessionID, markdown: text)
                    }
                )

                VStack(alignment: .leading, spacing: HarcSpacing.sm) {
                    Text("Recordings")
                        .font(.harcLabel)
                        .foregroundStyle(.secondary)
                    ForEach(members) { rec in
                        memberRow(rec)
                    }
                }

                Button("Dissolve Session…", role: .destructive) {
                    onDissolve(session)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove the grouping. The recordings stay in the library.")
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding([.horizontal, .top])
            .padding(.bottom, HarcSpacing.lg)
        }
        .navigationTitle(session.displayTitle)
    }

    private func titleRow(session: Session) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
            TextField("Session · \(session.day)", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { commitTitle(session: session) }
            Spacer(minLength: 8)
            if let renameError {
                Label(renameError, systemImage: "exclamationmark.triangle.fill")
                    .font(.harcCaption)
                    .foregroundStyle(Color.harc(.attention))
                    .lineLimit(1)
                    .help(renameError)
            }
        }
    }

    @ViewBuilder
    private func summaryCard(session: Session) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.md) {
            HStack {
                Text("Session Summary")
                    .font(.harcLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onSummarize {
                    Button(session.summaryMarkdown == nil ? "Summarize" : "Regenerate") {
                        onSummarize(sessionID)
                    }
                    .controlSize(.small)
                }
            }

            if let summary = session.summaryMarkdown, !summary.isEmpty {
                Text(markdown: summary)
                    .font(.harcBody)
                    .textSelection(.enabled)
                if let actions = session.actionItemsMarkdown, !actions.isEmpty {
                    Text("Action Items")
                        .font(.harcLabel)
                        .foregroundStyle(.secondary)
                    Text(markdown: actions)
                        .font(.harcBody)
                        .textSelection(.enabled)
                }
            } else if let kind = session.summaryStatusKind {
                Label(
                    session.summaryStatusMessage ?? defaultStatusMessage(kind),
                    systemImage: kind == .failed
                        ? "exclamationmark.triangle.fill"
                        : "info.circle"
                )
                .font(.harcCaption)
                .foregroundStyle(kind == .failed ? Color.harc(.failure) : Color.secondary)
            } else {
                Text("One combined summary across every recording in this session.")
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(HarcSpacing.md)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memberRow(_ rec: Recording) -> some View {
        Button {
            onSelectRecording(rec)
        } label: {
            HStack(alignment: .top, spacing: HarcSpacing.sm) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.displayTitle)
                        .font(.harcBody)
                        .lineLimit(1)
                    Text(HarcWindowRootView.rowSecondaryLine(for: rec))
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.harcCaption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, HarcSpacing.xs)
    }

    private func defaultStatusMessage(_ kind: RecordingSummaryStatusKind) -> String {
        switch kind {
        case .failed: return "The last summarization attempt failed."
        case .skipped: return "Summarization was skipped."
        }
    }

    private func commitTitle(session: Session) {
        guard let id = session.id else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = session.title ?? ""
        guard trimmed != current else { return }
        Task {
            do {
                try await store.updateSessionTitle(id: id, title: trimmed.isEmpty ? nil : trimmed)
                renameError = nil
            } catch {
                renameError = "Couldn't rename: \(error.localizedDescription)"
            }
        }
    }

    /// Track the session row and its members. The overview stream refires on
    /// any sessions / membership / member-row change, so one loop covers
    /// renames, summary landings, and member edits alike.
    private func observe() async {
        for await overviews in store.observeSessionOverviews() {
            guard let overview = overviews.first(where: { $0.id == sessionID }) else {
                session = nil
                members = []
                return
            }
            let fetched = (try? await store.recordings(inSession: sessionID)) ?? []
            session = overview.session
            members = fetched
            let loaded = overview.session.title ?? ""
            if titleDraft == (lastLoadedTitle ?? "") {
                titleDraft = loaded
            }
            lastLoadedTitle = loaded
        }
    }
}

// Same markdown-safe Text helper the summary card uses; model-generated
// content must not run through LocalizedStringKey.
private extension Text {
    init(markdown: String) {
        if let attr = try? AttributedString(markdown: markdown) {
            self.init(attr)
        } else {
            self.init(verbatim: markdown)
        }
    }
}
