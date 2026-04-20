import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarcStore
import HarcExport

/// Identifiable wrapper so SwiftUI Table can use `wavPath` (non-optional String)
/// as the row id. `Recording.id` is `Int64?`, which makes the Table's
/// `.contextMenu(forSelectionType:)` + `primaryAction` machinery unreliable.
private struct LibraryRow: Identifiable {
    let recording: Recording
    var id: String { recording.wavPath }
}

public struct LibraryWindowRootView: View {
    @EnvironmentObject private var vm: LibraryViewModel
    @State private var renameTarget: Recording?
    @State private var renameText: String = ""
    @State private var selectedWavPath: String?
    @State private var exportErrorMessage: String?

    private var selectedRecording: Recording? {
        guard let path = selectedWavPath else { return nil }
        if let hit = vm.hits.first(where: { $0.recording.wavPath == path }) {
            return hit.recording
        }
        return vm.recordings.first { $0.wavPath == path }
    }

    let onOpen: (Recording) -> Void
    let onOpenInEditor: (Recording) -> Void
    let onOpenSettings: () -> Void

    public init(
        onOpen: @escaping (Recording) -> Void,
        onOpenInEditor: @escaping (Recording) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onOpenInEditor = onOpenInEditor
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            main
                .frame(minWidth: 480)
            detail
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
        }
        .frame(minWidth: 1040, minHeight: 560)
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
            if vm.searchText.isEmpty {
                list
            } else {
                searchResultsList
            }
            statusStrip
        }
        .padding(HarcDesign.Space.lg)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if vm.hits.isEmpty {
            VStack {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.4))
                Text("No matches for \u{201C}\(vm.searchText)\u{201D}")
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcOnSurfaceVariant)
                    .padding(.top, HarcDesign.Space.xs)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.hits) { hit in
                        TranscriptHitRow(hit: hit) { onOpen(hit.recording) }
                            .background(
                                selectedWavPath == hit.recording.wavPath
                                    ? Color.harcPrimary.opacity(0.08)
                                    : Color.clear
                            )
                            .onTapGesture {
                                selectedWavPath = hit.recording.wavPath
                            }
                        Divider().background(Color.harcOutlineVariant.opacity(0.2))
                    }
                }
            }
        }
    }

    private var statusStrip: some View {
        HStack {
            Text(vm.searchText.isEmpty
                 ? "\(vm.recordings.count) files"
                 : "\(vm.hits.count) match\(vm.hits.count == 1 ? "" : "es")")
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

    @ViewBuilder
    private var detail: some View {
        if let rec = selectedRecording {
            detailContent(for: rec)
        } else {
            detailEmpty
        }
    }

    private var detailEmpty: some View {
        VStack(spacing: HarcDesign.Space.sm) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 36))
                .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.4))
            Text("Select a recording")
                .font(HarcDesign.Font.bodyMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(HarcDesign.Space.lg)
    }

    private func detailContent(for rec: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcDesign.Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                        .fill(Color.harcPrimary.opacity(0.14))
                        .frame(height: 140)
                    Button {
                        onOpenInEditor(rec)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.harcPrimary)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                    Text("FILE DETAILS")
                        .font(HarcDesign.Font.labelMd)
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                        .tracking(1.2)
                    detailRow(label: "Recording Date", value: formatFullDate(rec.startedAt))
                    detailRow(label: "Duration",       value: formatDuration(rec))
                    detailRow(label: "File",           value: URL(fileURLWithPath: rec.wavPath).lastPathComponent)
                    if !rec.tags.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tags")
                                .font(HarcDesign.Font.labelMd)
                                .foregroundStyle(Color.harcOnSurfaceVariant)
                            HStack(spacing: 4) {
                                ForEach(rec.tags, id: \.self) { TagChip($0) }
                            }
                        }
                    }
                }

                if !rec.preview.isEmpty {
                    VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
                        Text("AI SUMMARY")
                            .font(HarcDesign.Font.labelMd)
                            .foregroundStyle(Color.harcOnSurfaceVariant)
                            .tracking(1.2)
                        Text(rec.preview)
                            .font(HarcDesign.Font.bodySm)
                            .foregroundStyle(Color.harcOnSurface)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            onOpen(rec)
                        } label: {
                            Text("Read Full Transcript →")
                                .font(HarcDesign.Font.labelMd)
                                .foregroundStyle(Color.harcPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                exportControls(for: rec)

                Spacer(minLength: 0)
            }
            .padding(HarcDesign.Space.lg)
        }
    }

    private func exportControls(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: HarcDesign.Space.xs) {
            Text("EXPORT")
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
                .tracking(1.2)
            HStack(spacing: HarcDesign.Space.sm) {
                Menu {
                    Button("Export Markdown…")    { runExport(rec, format: .markdown) }
                    Button("Export DOCX…")        { runExport(rec, format: .docx) }
                    Button("Export for Prompt…")  { runExport(rec, format: .prompt) }
                    Divider()
                    Button("Copy for Prompt")     { copyPromptString(rec) }
                    Button("Copy Plain Text")     { copyPlainText(rec) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export")
                    }
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    copyPromptString(rec)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Copy for Prompt")
                    }
                    .font(HarcDesign.Font.bodyMd)
                    .foregroundStyle(Color.harcPrimary)
                }
                .buttonStyle(.plain)
            }
            if let msg = exportErrorMessage {
                Text(msg)
                    .font(HarcDesign.Font.labelMd)
                    .foregroundStyle(Color.harcError)
            }
        }
    }

    private func copyPromptString(_ rec: Recording) {
        let s = ExportService.promptString(for: rec)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        exportErrorMessage = nil
    }

    private func copyPlainText(_ rec: Recording) {
        let input = ExportInputBuilder.build(from: rec)
        let text = input.segments.map { $0.text }.joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        exportErrorMessage = nil
    }

    private func runExport(_ rec: Recording, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportService
            .defaultDestination(for: rec, format: format)
            .lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: rec.wavPath).deletingLastPathComponent()
        if let contentType = UTType(filenameExtension: format.filenameExtension) {
            panel.allowedContentTypes = [contentType]
        }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ExportService.write(recording: rec, format: format, to: url)
                exportErrorMessage = nil
            } catch {
                exportErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(HarcDesign.Font.labelMd)
                .foregroundStyle(Color.harcOnSurfaceVariant)
            Text(value)
                .font(HarcDesign.Font.bodySm)
                .foregroundStyle(Color.harcOnSurface)
        }
    }

    private func formatFullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
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
            Table(vm.recordings.map(LibraryRow.init), selection: $selectedWavPath) {
                TableColumn("Name & Date") { row in
                    let rec = row.recording
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
                TableColumn("Duration") { row in
                    Text(formatDuration(row.recording))
                        .font(HarcDesign.Font.bodySm.monospacedDigit())
                        .foregroundStyle(Color.harcOnSurfaceVariant)
                }
                .width(min: 70, ideal: 80, max: 100)
                TableColumn("Tags") { row in
                    if row.recording.tags.isEmpty {
                        Text("—")
                            .font(HarcDesign.Font.labelMd)
                            .foregroundStyle(Color.harcOnSurfaceVariant.opacity(0.5))
                    } else {
                        HStack(spacing: 4) {
                            ForEach(row.recording.tags.prefix(3), id: \.self) { TagChip($0) }
                        }
                    }
                }
                TableColumn("Actions") { row in
                    let rec = row.recording
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
            .contextMenu(forSelectionType: String.self, menu: { paths in
                if let path = paths.first, let rec = vm.recordings.first(where: { $0.wavPath == path }) {
                    Button("Rename…") {
                        renameTarget = rec
                        renameText = rec.title ?? ""
                    }
                    Button("Open in Editor") { onOpenInEditor(rec) }
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
            }, primaryAction: { paths in
                if let path = paths.first, let rec = vm.recordings.first(where: { $0.wavPath == path }) {
                    onOpenInEditor(rec)
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
