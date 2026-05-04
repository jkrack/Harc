import SwiftUI
import HarcStore

public struct PersonDetailView: View {
    let personID: Int64
    let onSelectRecording: (Int64, Int) -> Void

    @StateObject private var viewModel: PersonDetailViewModel

    public init(personID: Int64, store: RecordingStore, onSelectRecording: @escaping (Int64, Int) -> Void) {
        self.personID = personID
        self.onSelectRecording = onSelectRecording
        _viewModel = StateObject(wrappedValue: PersonDetailViewModel(store: store))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let stats = viewModel.stats { statsLine(stats) }
                utterancesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: personID) {
            await viewModel.load(personID: personID)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PersonAvatar(displayName: viewModel.person?.displayName ?? "?", size: 44)
            Text(viewModel.person?.displayName ?? "Loading\u{2026}")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            // Rename / Delete land in Phase 7.
        }
    }

    @ViewBuilder
    private func statsLine(_ stats: PersonStats) -> some View {
        HStack(spacing: 8) {
            Text("\(stats.recordingCount) \(stats.recordingCount == 1 ? "recording" : "recordings")")
            Text("\u{00B7}").foregroundStyle(.secondary)
            Text(formatMs(stats.totalSpeakingMs)).foregroundStyle(.secondary)
            if let last = stats.lastSeen {
                Text("\u{00B7}").foregroundStyle(.secondary)
                Text("last seen \(last, style: .date)").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var utterancesSection: some View {
        if !viewModel.utterances.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent utterances").font(.headline)
                ForEach(viewModel.utterances) { u in
                    Button {
                        onSelectRecording(u.recordingID, u.speakerIndex)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(u.recordingTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text("\u{00B7}").foregroundStyle(.secondary)
                                Text(formatTimestamp(u.startMs))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(u.snippet)
                                .font(.body)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        } else if viewModel.person != nil && viewModel.stats?.recordingCount == 0 {
            Text("No recordings yet. The next time this voice appears in a recording, link it from the Inspector to start building \(viewModel.person?.displayName ?? "this person")'s history.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func formatMs(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total / 60) % 60
        if h > 0 { return "\(h)h \(m)m total" }
        return "\(m)m total"
    }

    private func formatTimestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
