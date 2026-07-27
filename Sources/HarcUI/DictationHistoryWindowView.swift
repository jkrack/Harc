import SwiftUI
import AppKit

/// Full dictation-history window: searchable entry list with a detail pane
/// offering voice-vs-AI views, copy, re-process with any LLM mode, and
/// per-entry delete. Replaces squinting at the menu-bar quick list.
public struct DictationHistoryWindowView: View {
    @ObservedObject var historyStore: DictationHistoryStore
    @ObservedObject var modeStore: DictationModeStore
    /// Re-process seam: (source text, mode) → transformed text. Same seam the
    /// settings "Test" button uses; nil hides the re-process control.
    let reprocess: ((String, DictationMode) async throws -> String)?

    @State private var searchText = ""
    @State private var selectedID: String?
    /// Per-entry view toggle: false = delivered (AI) text, true = raw voice.
    @State private var showingVoice = false
    @State private var reprocessResult: String?
    @State private var reprocessModeName: String?
    @State private var reprocessRunning = false
    @State private var confirmingClearAll = false

    public init(
        historyStore: DictationHistoryStore,
        modeStore: DictationModeStore,
        reprocess: ((String, DictationMode) async throws -> String)? = nil
    ) {
        self.historyStore = historyStore
        self.modeStore = modeStore
        self.reprocess = reprocess
    }

    public var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
            detailPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 380)
        .onChange(of: selectedID) { _, _ in
            showingVoice = false
            reprocessResult = nil
            reprocessModeName = nil
        }
    }

    // MARK: - List pane

    var filteredEntries: [DictationHistoryEntry] {
        Self.filter(historyStore.entries, query: searchText)
    }

    /// Search matches the delivered text AND the raw transcript, so a
    /// dictation is findable by what you said, not just what a mode made of it.
    static func filter(_ entries: [DictationHistoryEntry], query: String) -> [DictationHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            entry.text.localizedCaseInsensitiveContains(trimmed)
                || (entry.rawText?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dictations", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(HarcSpacing.sm)
            Divider()

            if filteredEntries.isEmpty {
                VStack(spacing: HarcSpacing.sm) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(historyStore.entries.isEmpty
                         ? "No dictations yet"
                         : "No matches")
                        .font(.harcBody)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Copy") { copy(entry.text) }
                                Button("Delete", role: .destructive) {
                                    delete(entry)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(historyStore.entries.count) of \(DictationHistoryStore.maxEntries) kept")
                    .font(.harcCaption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear History", role: .destructive) {
                    confirmingClearAll = true
                }
                .controlSize(.small)
                .disabled(historyStore.entries.isEmpty)
                .confirmationDialog(
                    "Clear all dictation history?",
                    isPresented: $confirmingClearAll
                ) {
                    Button("Clear All", role: .destructive) {
                        historyStore.clear()
                        selectedID = nil
                    }
                }
            }
            .padding(HarcSpacing.sm)
        }
    }

    private func entryRow(_ entry: DictationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                .font(.harcBody)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 5) {
                Text(entry.modeName)
                    .font(.harcCaption.weight(.medium))
                if let app = entry.targetAppName {
                    Text("→ \(app)")
                        .font(.harcCaption)
                }
                if entry.delivery == .copied {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 8))
                        .help("Copied to clipboard (not inserted)")
                }
                Spacer()
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.harcCaption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail pane

    private var selectedEntry: DictationHistoryEntry? {
        historyStore.entries.first { $0.id == selectedID }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                detailHeader(entry)
                if entry.rawText != nil {
                    Picker("", selection: $showingVoice) {
                        Text(entry.modeName).tag(false)
                        Text("Voice").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                ScrollView {
                    Text(displayText(for: entry))
                        .font(.harcBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let reprocessResult {
                    reprocessResultView(reprocessResult)
                }
                Spacer(minLength: 0)
                detailActions(entry)
            }
            .padding(HarcSpacing.lg)
        } else {
            VStack {
                Spacer()
                Text("Select a dictation")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detailHeader(_ entry: DictationHistoryEntry) -> some View {
        HStack(spacing: HarcSpacing.sm) {
            Text(entry.modeName)
                .font(.harcTitle)
            if let app = entry.targetAppName {
                Text(entry.delivery == .pasted ? "inserted into \(app)" : "copied (\(app) frontmost)")
                    .font(.harcLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.harcCaption)
                .foregroundStyle(.secondary)
        }
    }

    private func displayText(for entry: DictationHistoryEntry) -> String {
        showingVoice ? (entry.rawText ?? entry.text) : entry.text
    }

    private func reprocessResultView(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: HarcSpacing.sm) {
            HStack {
                Text(reprocessModeName.map { "As \($0)" } ?? "Result")
                    .font(.harcCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copy(result) }
                    .controlSize(.small)
            }
            ScrollView {
                Text(result)
                    .font(.harcBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding(HarcSpacing.md)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func detailActions(_ entry: DictationHistoryEntry) -> some View {
        HStack(spacing: HarcSpacing.sm) {
            Button("Copy") { copy(displayText(for: entry)) }
            if reprocess != nil {
                reprocessMenu(entry)
                if reprocessRunning {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
            Button(role: .destructive) {
                delete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete this dictation")
        }
    }

    /// Re-run any LLM mode over the dictation's voice transcript (falling
    /// back to the delivered text for raw dictations).
    private func reprocessMenu(_ entry: DictationHistoryEntry) -> some View {
        Menu("Re-process") {
            ForEach(modeStore.modes.filter { $0.postProcess == .llm }) { mode in
                Button(mode.name) { runReprocess(entry, mode: mode) }
            }
        }
        .fixedSize()
        .disabled(reprocessRunning)
    }

    private func runReprocess(_ entry: DictationHistoryEntry, mode: DictationMode) {
        guard let reprocess else { return }
        reprocessRunning = true
        reprocessResult = nil
        reprocessModeName = mode.name
        let source = entry.rawText ?? entry.text
        Task { @MainActor in
            defer { reprocessRunning = false }
            do {
                reprocessResult = try await reprocess(source, mode)
            } catch {
                reprocessResult = "Unavailable: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        FrontmostAppPaster.copyOnly(text)
    }

    private func delete(_ entry: DictationHistoryEntry) {
        if selectedID == entry.id { selectedID = nil }
        historyStore.delete(id: entry.id)
    }
}
