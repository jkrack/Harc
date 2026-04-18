import SwiftUI
import AppKit
import HarcStore

public struct LibraryWindowRootView: View {
    @EnvironmentObject private var vm: LibraryViewModel

    let onOpen: (Recording) -> Void

    public init(onOpen: @escaping (Recording) -> Void) {
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            LibrarySearchField(text: $vm.searchText)
            list
        }
        .padding(HarcDesign.Space.lg)
        .frame(minWidth: 680, minHeight: 480)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    @ViewBuilder
    private var list: some View {
        if vm.recordings.isEmpty {
            VStack {
                Spacer()
                Text(vm.searchText.isEmpty ? "No recordings yet." : "No matches.")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Spacer()
            }
        } else {
            List(vm.recordings) { rec in
                row(for: rec)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(rec) }
                    .contextMenu {
                        Button("Open") { onOpen(rec) }
                        Button(rec.pinned ? "Unpin" : "Pin") {
                            Task { try? await vm.togglePin(id: rec.id ?? -1, currentlyPinned: rec.pinned) }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
                        }
                        Divider()
                        Button(role: .destructive) {
                            Task { try? await vm.delete(id: rec.id ?? -1) }
                        } label: {
                            Text("Delete")
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private func row(for rec: Recording) -> some View {
        HStack(alignment: .top, spacing: HarcDesign.Space.sm) {
            Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                .foregroundStyle(rec.pinned ? Color.harcTertiary : Color.harcPrimary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.displayTitle)
                    .font(HarcDesign.Font.titleSm)
                    .foregroundStyle(Color.harcOnSurface)
                if !rec.preview.isEmpty {
                    Text(rec.preview)
                        .font(HarcDesign.Font.bodySm)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, HarcDesign.Space.xxs)
    }
}
