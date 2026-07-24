import SwiftUI

/// Settings as a sidebar + detail split, the shape macOS System Settings
/// itself uses. It replaced a single 21-section scroll: the section count
/// had outgrown one page, related settings had drifted apart (transcription
/// knobs lived in three non-adjacent places), and a flat form has nowhere to
/// link to — cross-references had decayed into "the section below".
public struct HarcSettingsForm: View {
    @State private var selection: SettingsPane? = .general
    @State private var query = ""

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if isSearching {
                searchResults
            } else {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbolName)
                        .tag(pane)
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsSearchIndex.results(for: query)
        if results.isEmpty {
            Text("No settings match “\(query.trimmingCharacters(in: .whitespaces))”.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .padding(.vertical, 4)
        } else {
            // Grouped by pane so a hit reads as "Speakers — in Transcription",
            // which teaches where the setting lives instead of teleporting to
            // it with no context.
            ForEach(panesWithResults(results), id: \.self) { pane in
                Section(pane.title) {
                    ForEach(results.filter { $0.pane == pane }) { entry in
                        Label(entry.label, systemImage: pane.symbolName)
                            .tag(pane)
                    }
                }
            }
        }
    }

    private func panesWithResults(_ results: [SettingsSearchEntry]) -> [SettingsPane] {
        SettingsPane.allCases.filter { pane in results.contains { $0.pane == pane } }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let pane = selection ?? .general
        Form {
            switch pane {
            case .general:
                GeneralSettingsView()
            case .recording:
                RecordingSettingsView()
            case .transcription:
                TranscriptionSettingsView()
            case .dictation:
                DictationSettingsView()
            case .modes:
                DictationModesSettingsView()
            case .ai:
                AIModelsSettingsView()
            case .about:
                AboutSettingsView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(pane.title)
    }
}
