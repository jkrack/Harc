import SwiftUI

public struct RecentRecordingsView: View {
    @EnvironmentObject private var index: RecordingsIndex

    /// Called when the user clicks a row.
    let onOpen: (RecordingEntry) -> Void

    public init(onOpen: @escaping (RecordingEntry) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("Recent")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1.2)

            if index.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(index.entries.prefix(8)) { entry in
                            row(for: entry)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var emptyState: some View {
        Text("No recordings yet. Press Start Recording to begin.")
            .font(HarcDesign.Font.bodySm)
            .foregroundStyle(Color.harcOnSurfaceVariant)
            .padding(.vertical, HarcDesign.Space.sm)
    }

    private func row(for entry: RecordingEntry) -> some View {
        Button { onOpen(entry) } label: {
            HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.harcPrimary)
                    .frame(width: 24, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date)
                        .font(HarcDesign.Font.titleSm)
                        .foregroundStyle(Color.harcOnSurface)
                        .lineLimit(1)
                    if let preview = entry.preview, !preview.isEmpty {
                        Text(preview)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                            .lineLimit(2)
                    } else {
                        Text("(no transcript)")
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.vertical, HarcDesign.Space.xs)
            .padding(.horizontal, HarcDesign.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
