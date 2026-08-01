import SwiftUI

/// Editable free-form notes card, shared by the recording and session
/// detail panes. Autosaves on pause (~1.5s after the last keystroke) and
/// flushes on disappear, mirroring the transcript editor's contract: what's
/// on screen is what's saved.
///
/// Agents append to the same field through harc-mcp, so an external edit
/// can land while the card is visible — the draft refreshes only when the
/// user hasn't diverged from the last loaded value (same guard the session
/// title uses).
struct NotesCardView: View {
    /// Identity of the row the notes belong to — the draft reloads when
    /// this changes.
    let itemID: Int64
    /// Current persisted value, from the observing parent.
    let notes: String?
    let onSave: (String?) async throws -> Void

    @State private var draft = ""
    @State private var lastLoaded: String?
    @State private var saveError: String?
    @State private var dirty = false
    @State private var autosaveTask: Task<Void, Never>? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            HStack {
                Text("Notes")
                    .font(.harcLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.harcCaption)
                        .foregroundStyle(Color.harc(.attention))
                        .lineLimit(1)
                        .help(saveError)
                } else if dirty {
                    Text("Editing…")
                        .font(.harcCaption)
                        .foregroundStyle(.tertiary)
                }
            }

            TextEditor(text: $draft)
                .font(.harcBody)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 54, maxHeight: 140)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Add context, links, or follow-ups. Agents connected over MCP append here too.")
                            .font(.harcBody)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(HarcSpacing.md)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .task(id: itemID) {
            draft = notes ?? ""
            lastLoaded = notes
            dirty = false
            saveError = nil
        }
        .onChange(of: notes) { _, newValue in
            // External change (agent append, other window). Refresh only if
            // the user hasn't typed past the last loaded state.
            if !dirty || draft == (lastLoaded ?? "") {
                draft = newValue ?? ""
                dirty = false
            }
            lastLoaded = newValue
        }
        .onChange(of: draft) { _, _ in
            guard draft != (lastLoaded ?? "") else { return }
            dirty = true
            scheduleAutosave()
        }
        .onDisappear { flush() }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [text = draft] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await save(text: text)
        }
    }

    private func flush() {
        autosaveTask?.cancel()
        guard dirty else { return }
        let text = draft
        Task { await save(text: text) }
    }

    private func save(text: String) async {
        guard dirty else { return }
        do {
            try await onSave(text.isEmpty ? nil : text)
            dirty = (draft != text)
            lastLoaded = text.isEmpty ? nil : text
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
