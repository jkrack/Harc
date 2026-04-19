import SwiftUI
import AppKit
import HarcStore

public struct LibraryWindowRootView: View {
    @EnvironmentObject private var vm: LibraryViewModel
    @State private var renameTarget: Recording?
    @State private var renameText: String = ""
    @State private var selectedID: Int64?

    private var selectedRecording: Recording? {
        guard let id = selectedID else { return nil }
        return vm.recordings.first { $0.id == id }
    }

    let onOpen: (Recording) -> Void
    let onOpenSettings: () -> Void

    public init(
        onOpen: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            main
                .frame(minWidth: 480)
        }
        .frame(minWidth: 780, minHeight: 520)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .alert("Rename recording", isPresented: .constant(renameTarget != nil), presenting: renameTarget) { rec in
            TextField("Title", text: $renameText)
            Button("Save") {
                let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    try? await vm.rename(id: rec.id ?? -1, title: newTitle.isEmpty ? nil : newTitle)
                    renameTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: { _ in
            Text("Leave empty to clear the custom title.")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            brandHeader
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            quickFilters
            Divider().background(Color.harcOutlineVariant.opacity(0.3))
            MonthCalendarView(
                month: vm.calendarMonth,
                selectedDay: selectedDay,
                daysWithRecordings: vm.daysWithRecordings,
                onPrevMonth: { vm.advanceMonth(by: -1) },
                onNextMonth: { vm.advanceMonth(by: 1) },
                onSelectDay: { day in vm.filter = .day(day) }
            )
            Spacer()
            sidebarFooter
        }
        .padding(HarcDesign.Space.md)
    }

    private var brandHeader: some View {
        HStack(spacing: HarcDesign.Space.sm) {
            RecordingIconTile(systemImage: "waveform", accent: .harcPrimary, size: 36)
            VStack(alignment: .leading, spacing: 0) {
                Text("Harc")
                    .font(HarcDesign.Font.titleLg)
                    .foregroundStyle(Color.harcOnSurface)
                Text("LOCAL LIBRARY")
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .tracking(1.2)
            }
            Spacer()
        }
    }

    private var sidebarFooter: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: HarcDesign.Space.xs) {
                Image(systemName: "gearshape")
                    .frame(width: 16)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Text("Settings")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurface)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, HarcDesign.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quickFilters: some View {
        VStack(alignment: .leading, spacing: 2) {
            filterRow("All",       filter: .all,       systemImage: "tray.2")
            filterRow("Today",     filter: .today,     systemImage: "sun.max")
            filterRow("Yesterday", filter: .yesterday, systemImage: "clock.arrow.circlepath")
            filterRow("This Week", filter: .thisWeek,  systemImage: "calendar")
            filterRow("Pinned",    filter: .pinned,    systemImage: "pin.fill")
        }
    }

    private func filterRow(_ label: String, filter: LibraryFilter, systemImage: String) -> some View {
        Button {
            vm.filter = filter
        } label: {
            HStack(spacing: HarcDesign.Space.xs) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(vm.filter == filter ? Color.harcPrimary : Color.harcOnSurfaceVariant)
                Text(label)
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurface)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, HarcDesign.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(vm.filter == filter ? Color.harcPrimary.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedDay: Date? {
        if case .day(let d) = vm.filter { return d }
        return nil
    }

    // MARK: Main list

    private var main: some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
            LibrarySearchField(text: $vm.searchText)
            list
            statusStrip
        }
        .padding(HarcDesign.Space.lg)
    }

    private var statusStrip: some View {
        HStack {
            Text("\(vm.recordings.count) files")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Text("·")
                .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.5))
            Text(storageUsed)
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Spacer()
            Text("LOCAL")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcPrimary)
                .tracking(1.2)
        }
    }

    private var storageUsed: String {
        let fm = FileManager.default
        var total: Int64 = 0
        for rec in vm.recordings {
            if let attrs = try? fm.attributesOfItem(atPath: rec.wavPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: total)
    }

    @ViewBuilder
    private var list: some View {
        if vm.recordings.isEmpty {
            VStack {
                Spacer()
                Text(vm.searchText.isEmpty ? "No recordings." : "No matches.")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                Spacer()
            }
        } else {
            Table(vm.recordings, selection: Binding<Int64??>(
                get: { selectedID },
                set: { selectedID = $0 ?? nil }
            )) {
                TableColumn("Name & Date") { rec in
                    HStack(alignment: .center, spacing: HarcDesign.Space.xs) {
                        RecordingIconTile(
                            systemImage: rec.pinned ? "pin.fill" : "waveform",
                            accent: rec.pinned ? .harcTertiary : .harcPrimary,
                            size: 28
                        )
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rec.displayTitle)
                                .font(HarcDesign.Font.titleSm)
                                .foregroundStyle(Color.harcOnSurface)
                                .lineLimit(1)
                            Text(RelativeTimeFormatter.format(rec.startedAt))
                                .font(HarcDesign.Font.labelMd)
                                .foregroundStyle(Color.harcOnSurfaceVariant)
                        }
                    }
                }
                TableColumn("Duration") { rec in
                    Text(formatDuration(rec))
                        .font(HarcDesign.Font.bodySm.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Tags") { rec in
                    if rec.tags.isEmpty {
                        Text("—")
                            .font(HarcDesign.Font.labelMd)
                            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.5))
                    } else {
                        HStack(spacing: 4) {
                            ForEach(rec.tags.prefix(3), id: \.self) { TagChip($0) }
                        }
                    }
                }
                TableColumn("Actions") { rec in
                    HStack(spacing: HarcDesign.Space.xxs) {
                        Button { onOpen(rec) } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }.buttonStyle(.plain).help("Open")
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
                        } label: {
                            Image(systemName: "folder")
                        }.buttonStyle(.plain).help("Reveal in Finder")
                    }
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                .width(min: 60, ideal: 72, max: 90)
            }
            .tableStyle(.inset)
            .contextMenu(forSelectionType: Int64.self, menu: { ids in
                if let id = ids.first, let rec = vm.recordings.first(where: { $0.id == id }) {
                    Button("Rename…") {
                        renameTarget = rec
                        renameText = rec.title ?? ""
                    }
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
            }, primaryAction: { ids in
                if let id = ids.first, let rec = vm.recordings.first(where: { $0.id == id }) {
                    onOpen(rec)
                }
            })
        }
    }

    private func formatDuration(_ rec: Recording) -> String {
        guard let end = rec.endedAt else { return "—" }
        let seconds = Int(end.timeIntervalSince(rec.startedAt))
        let m = seconds / 60, s = seconds % 60
        if m >= 60 {
            let h = m / 60, mm = m % 60
            return String(format: "%d:%02d:%02d", h, mm, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
