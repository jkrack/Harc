import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HarcStore
import HarcExport

public struct LibraryWindowRootView: View {
    @EnvironmentObject private var vm: LibraryViewModel
    @State private var renameTarget: Recording?
    @State private var renameText: String = ""
    @State private var selectedWavPath: String?
    @State private var hoveredRowId: String?
    @State private var rowHeight: CGFloat = HarcDesign.Layout.rowHeightCompact
    @State private var showStackedRail: Bool = true
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
        HStack(spacing: 0) {
            sidebar
                .frame(width: HarcDesign.Layout.sidebarWidth)
                .background(Color.harcSurface1)

            verticalHairline

            main
                .frame(maxWidth: .infinity)
                .background(Color.harcSurface2)

            verticalHairline

            detail
                .frame(width: HarcDesign.Layout.railWidth)
                .background(Color.harcSurface1)
        }
        .frame(minWidth: 1100, minHeight: 600)
        .background(Color.harcSurface0)
        .preferredColorScheme(.dark)
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

    private var verticalHairline: some View {
        Rectangle()
            .fill(Color.harcBorderSubtle)
            .frame(width: 1)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            quickFilters
                .padding(.horizontal, 8)
                .padding(.bottom, 12)

            Divider().background(Color.harcBorderSubtle)

            MonthCalendarView(
                month: vm.calendarMonth,
                selectedDay: selectedDay,
                daysWithRecordings: vm.daysWithRecordings,
                onPrevMonth: { vm.advanceMonth(by: -1) },
                onNextMonth: { vm.advanceMonth(by: 1) },
                onSelectDay: { day in vm.filter = .day(day) }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Spacer(minLength: 0)

            Divider().background(Color.harcBorderSubtle)
            sidebarFooter
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(HarcDesign.primaryGradient)
                    .frame(width: 28, height: 28)
                    .shadow(color: Color.harcAccent.opacity(0.4), radius: 6, x: 0, y: 4)
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Harc")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.harcInkPrimary)
                Text("LOCAL LIBRARY")
                    .font(HarcDesign.Font.monoXs)
                    .foregroundStyle(Color.harcInkTertiary)
                    .tracking(1.4)
            }
            Spacer(minLength: 0)
        }
    }

    private var sidebarFooter: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.harcInkTertiary)
                Text("Settings")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkSecondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quickFilters: some View {
        VStack(alignment: .leading, spacing: 1) {
            filterRow("All",       filter: .all,       systemImage: "tray.2")
            filterRow("Today",     filter: .today,     systemImage: "sun.max")
            filterRow("Yesterday", filter: .yesterday, systemImage: "moon")
            filterRow("This Week", filter: .thisWeek,  systemImage: "calendar")
            filterRow("Pinned",    filter: .pinned,    systemImage: "pin.fill")
        }
    }

    private func filterRow(_ label: String, filter: LibraryFilter, systemImage: String) -> some View {
        let active = vm.filter == filter
        return Button { vm.filter = filter } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14)
                    .foregroundStyle(active ? Color.harcAccent : Color.harcInkTertiary)
                Text(label)
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(active ? Color.harcInkPrimary : Color.harcInkSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active ? Color.harcSurface3 : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(active ? Color.harcBorderStrong : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedDay: Date? {
        if case .day(let d) = vm.filter { return d }
        return nil
    }

    // MARK: Main

    private var main: some View {
        VStack(spacing: 0) {
            searchBar
            tableHeader
            mainList
            footerStrip
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            LibrarySearchField(text: $vm.searchText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider().background(Color.harcBorderSubtle)
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 16) {
            headerCell("Name & Date", alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("Duration", alignment: .leading)
                .frame(width: 80, alignment: .leading)
            headerCell("Tags", alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell("Actions", alignment: .trailing)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.harcBorderSubtle)
                .frame(height: 1)
        }
    }

    private func headerCell(_ text: String, alignment: HorizontalAlignment) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(Color.harcInkTertiary)
    }

    @ViewBuilder
    private var mainList: some View {
        if vm.searchText.isEmpty {
            list
        } else {
            searchResultsList
        }
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if vm.hits.isEmpty {
            VStack(spacing: HarcDesign.Space.xs) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.harcInkQuaternary)
                Text("No matches for \u{201C}\(vm.searchText)\u{201D}")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.hits) { hit in
                        TranscriptHitRow(hit: hit) { onOpen(hit.recording) }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                selectedWavPath == hit.recording.wavPath
                                    ? Color.harcSelection
                                    : Color.clear
                            )
                            .overlay(alignment: .leading) {
                                if selectedWavPath == hit.recording.wavPath {
                                    Rectangle()
                                        .fill(Color.harcSelectionEdge)
                                        .frame(width: 3)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedWavPath = hit.recording.wavPath }
                        Divider().background(Color.harcBorderSubtle.opacity(0.6))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if vm.recordings.isEmpty {
            VStack(spacing: HarcDesign.Space.xs) {
                Spacer()
                Image(systemName: "waveform.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.harcInkQuaternary)
                Text("No recordings.")
                    .font(HarcDesign.Font.body)
                    .foregroundStyle(Color.harcInkSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.recordings) { rec in
                        recordingRow(rec)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private func recordingRow(_ rec: Recording) -> some View {
        let isSelected = selectedWavPath == rec.wavPath
        let isHovered  = hoveredRowId == rec.wavPath
        return HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: rec.pinned ? "pin.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isSelected ? .white : Color.harcAccent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(rec.displayTitle)
                        .font(HarcDesign.Font.body)
                        .fontWeight(.medium)
                        .foregroundStyle(isSelected ? .white : Color.harcInkPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(RelativeTimeFormatter.format(rec.startedAt))
                        .font(HarcDesign.Font.monoXs)
                        .foregroundStyle(isSelected
                                         ? Color.white.opacity(0.75)
                                         : Color.harcInkTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatDuration(rec))
                .font(HarcDesign.Font.mono)
                .monospacedDigit()
                .foregroundStyle(isSelected
                                 ? Color.white.opacity(0.85)
                                 : Color.harcInkSecondary)
                .frame(width: 80, alignment: .leading)

            TagsRow(tags: rec.tags, maxInline: 2)
                .opacity(isSelected ? 0.95 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                rowIconButton(systemImage: "rectangle.expand.vertical",
                              help: "Open recording",
                              isSelected: isSelected) {
                    onOpen(rec)
                }
                rowIconButton(systemImage: "folder",
                              help: "Reveal in Finder",
                              isSelected: isSelected) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
                }
            }
            .opacity(isSelected || isHovered ? 1 : 0.4)
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: rowHeight)
        .background(
            ZStack {
                if isSelected {
                    Color.harcSelection
                } else if isHovered {
                    Color.harcSurface3
                }
            }
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(Color.harcSelectionEdge)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.harcBorderSubtle.opacity(0.6))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRowId = hovering ? rec.wavPath : (hoveredRowId == rec.wavPath ? nil : hoveredRowId)
        }
        .onTapGesture(count: 2) { onOpen(rec) }
        .onTapGesture { selectedWavPath = rec.wavPath }
        .contextMenu {
            Button("Rename…") {
                renameTarget = rec
                renameText = rec.title ?? ""
            }
            Button("Open Recording") { onOpen(rec) }
            Button("Edit Transcript") { onOpenInEditor(rec) }
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

    private func rowIconButton(systemImage: String,
                               help: String,
                               isSelected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? Color.white : Color.harcInkTertiary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Footer

    private var footerStrip: some View {
        HStack(spacing: 0) {
            Text(footerLeft)
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkTertiary)
            Spacer()
            footerStatus
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Color.harcSurface1)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.harcBorderSubtle).frame(height: 1)
        }
    }

    private var footerLeft: String {
        let count = vm.searchText.isEmpty ? vm.recordings.count : vm.hits.count
        return "\(count) files · \(storageUsed)"
    }

    private var footerStatus: some View {
        HStack(spacing: 8) {
            Text("\(HardwareInfo.appleSiliconDisplayName) · Neural Engine")
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkSecondary)
            Text("·").foregroundStyle(Color.harcInkQuaternary)
            Text("parakeet-tdt-0.6b-v3")
                .font(HarcDesign.Font.monoXs)
                .foregroundStyle(Color.harcInkSecondary)
            Text("·").foregroundStyle(Color.harcInkQuaternary)
            Text("LOCAL")
                .font(HarcDesign.Font.monoXs)
                .tracking(1.0)
                .foregroundStyle(Color.harcAccent)
                .fontWeight(.medium)
        }
    }

    // MARK: Detail rail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            railHeader
            if let rec = selectedRecording {
                ScrollView {
                    detailContent(for: rec)
                        .padding(16)
                }
            } else {
                detailEmpty
            }
        }
    }

    private var railHeader: some View {
        HStack {
            Spacer()
            HStack(spacing: 2) {
                railVariantButton("Detail",  active: !showStackedRail) { showStackedRail = false }
                railVariantButton("Stacked", active:  showStackedRail) { showStackedRail = true }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(Color.harcSurface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                            .stroke(Color.harcBorderSubtle, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func railVariantButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(active ? Color.harcInkPrimary : Color.harcInkSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active ? Color.harcSurface4 : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var detailEmpty: some View {
        VStack(spacing: HarcDesign.Space.xs) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 32))
                .foregroundStyle(Color.harcInkQuaternary)
            Text("Select a recording")
                .font(HarcDesign.Font.body)
                .foregroundStyle(Color.harcInkTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailContent(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            playerCard(for: rec)
            fileDetailsSection(for: rec)
            exportSection(for: rec)
            if showStackedRail, !rec.preview.isEmpty {
                transcriptPreviewSection(for: rec)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ---- Rail: player card ----

    private func playerCard(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.harcAccent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recording")
                        .font(HarcDesign.Font.subtitle)
                        .foregroundStyle(Color.harcInkPrimary)
                    Text(URL(fileURLWithPath: rec.wavPath).lastPathComponent)
                        .font(HarcDesign.Font.monoXs)
                        .foregroundStyle(Color.harcInkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                recordingActionButton("Open", systemImage: "rectangle.expand.vertical") {
                    onOpen(rec)
                }
                recordingActionButton("Edit", systemImage: "pencil") {
                    onOpenInEditor(rec)
                }
                recordingIconButton(systemImage: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rec.wavPath)])
                }
            }

            HStack(spacing: 8) {
                Text(formatDuration(rec))
                Text("·").foregroundStyle(Color.harcInkQuaternary)
                Text(formatFullDate(rec.startedAt))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(HarcDesign.Font.monoXs)
            .foregroundStyle(Color.harcInkTertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                .fill(Color.harcSurface2)
                .overlay(
                    RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                        .stroke(Color.harcBorderSubtle, lineWidth: 1)
                )
        )
    }

    private func recordingActionButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(HarcDesign.Font.meta)
            }
            .foregroundStyle(Color.harcInkPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                    .fill(Color.harcSurface3)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                            .stroke(Color.harcBorderStrong, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func recordingIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.harcInkSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                        .fill(Color.harcSurface2)
                        .overlay(
                            RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                                .stroke(Color.harcBorderSubtle, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // ---- Rail: file details ----

    private func fileDetailsSection(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("File Details")
            VStack(spacing: 0) {
                detailKV("Recording Date", value: formatFullDate(rec.startedAt), mono: false)
                kvDivider()
                detailKV("Duration", value: formatDuration(rec), mono: true)
                kvDivider()
                detailKV(
                    "File",
                    value: URL(fileURLWithPath: rec.wavPath).lastPathComponent,
                    mono: true
                )
                if !rec.tags.isEmpty {
                    kvDivider()
                    HStack(alignment: .top, spacing: 12) {
                        Text("Tags")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.harcInkTertiary)
                            .frame(width: 92, alignment: .leading)
                        // Wrap tag pills inside the rail with no horizontal overflow.
                        FlowingTags(tags: rec.tags)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func detailKV(_ key: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.harcInkTertiary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(mono ? HarcDesign.Font.mono : .system(size: 12.5))
                .foregroundStyle(Color.harcInkPrimary)
                // CRITICAL: lets text wrap inside a narrow rail rather than push it.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    private func kvDivider() -> some View {
        Rectangle()
            .fill(Color.harcBorderSubtle)
            .frame(height: 1)
            .opacity(0.6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(HarcDesign.Font.monoXs)
            .tracking(1.4)
            .foregroundStyle(Color.harcInkTertiary)
    }

    // ---- Rail: export ----

    private func exportSection(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Export")
            HStack(spacing: 8) {
                Menu {
                    Section("Transcript") {
                        Button("Plain text · .txt") { runExport(rec, format: .prompt) }
                        Button("Markdown · .md")    { runExport(rec, format: .markdown) }
                    }
                    Section("Document") {
                        Button("DOCX · .docx")      { runExport(rec, format: .docx) }
                    }
                    Divider()
                    Button("Copy plain text") { copyPlainText(rec) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                        Text("Export")
                            .font(HarcDesign.Font.meta)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Color.harcInkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                            .fill(Color.harcSurface3)
                            .overlay(
                                RoundedRectangle(cornerRadius: HarcDesign.Radius.md, style: .continuous)
                                    .stroke(Color.harcBorderStrong, lineWidth: 1)
                            )
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Button { copyPromptString(rec) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .medium))
                        Text("Copy for Prompt")
                            .font(HarcDesign.Font.meta)
                    }
                    .foregroundStyle(Color.harcAccent)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if let msg = exportErrorMessage {
                Text(msg)
                    .font(HarcDesign.Font.label)
                    .foregroundStyle(Color.harcError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ---- Rail: transcript preview (Stacked variant) ----

    private func transcriptPreviewSection(for rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Transcript · Preview")
            ZStack(alignment: .bottom) {
                Text(rec.preview)
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(Color.harcInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .frame(maxHeight: 220, alignment: .top)
                    .clipped()
                LinearGradient(
                    colors: [Color.harcSurface1.opacity(0), Color.harcSurface1],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .allowsHitTesting(false)
            }
            .background(
                RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                    .fill(Color.harcSurface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: HarcDesign.Radius.lg, style: .continuous)
                            .stroke(Color.harcBorderSubtle, lineWidth: 1)
                    )
            )

            Button { onOpen(rec) } label: {
                Text("Open recording →")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.harcAccent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Export helpers

    private func copyPromptString(_ rec: Recording) {
        let s = ExportService.promptString(for: rec, includeSummary: HarcPreferences.shared.includeSummaryInPrompt)
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
                try ExportService.write(recording: rec, format: format, to: url, includeSummary: HarcPreferences.shared.includeSummaryInPrompt)
                exportErrorMessage = nil
            } catch {
                exportErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: Formatting helpers

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

// MARK: - Flowing tag wrap (used in the rail's Tags row)

private struct FlowingTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(tags, id: \.self) { TagChip($0) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                x = 0
                y += lineH + lineSpacing
                lineH = 0
            }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.minX + maxW, x > bounds.minX {
                x = bounds.minX
                y += lineH + lineSpacing
                lineH = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}
