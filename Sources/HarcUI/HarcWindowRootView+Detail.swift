import SwiftUI
import Foundation
import HarcStore
import HarcExport
import HarcClient
import HarcCore
import HarcModels
import HarcSummarize
import AppKit

// Detail-pane view code for `HarcWindowRootView`, split out of the main
// view file. Same type, same stored state — relocated into an extension to
// keep each file focused. Members it shares with the rest of the view are
// `internal` rather than `private`.

extension HarcWindowRootView {
    // MARK: - Detail

    @ViewBuilder
    var detail: some View {
        detailBody
            .safeAreaInset(edge: .top, spacing: 0) {
                if let mutationFailure {
                    mutationFailureBanner(mutationFailure)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
            }
    }

    @ViewBuilder
    var detailBody: some View {
        libraryDetail
    }

    func mutationFailureBanner(_ failure: LibraryMutationFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.caption.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button {
                mutationFailure = nil
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    var libraryDetail: some View {
        switch selection {
        case .person(let id):
            PersonDetailView(
                personID: id,
                store: store,
                onSelectRecording: { recID, _ in
                    // Swap to the recording's detail pane when the user taps an utterance.
                    if let rec = libraryVM.recordings.first(where: { $0.id == recID }) {
                        selection = .recording(wavPath: rec.wavPath)
                    }
                },
                onPersonDeleted: { selection = nil }
            )
        case .recording, .none:
            if let recording = selectedRecording {
                detailContent(recording: recording)
                    .inspector(isPresented: $inspectorOpen) {
                        inspectorContent(recording: recording)
                    }
            } else {
                ContentUnavailableView(
                    "No Item Selected",
                    systemImage: "sidebar.left",
                    description: Text("Pick a person or recording from the sidebar.")
                )
            }
        }
    }

    func detailContent(recording: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WaveformPlayerView(
                        envelope: detailEnvelope,
                        audioURL: URL(fileURLWithPath: recording.wavPath)
                    )
                    .padding(.horizontal)

                    inspectorSummaryChips(for: recording)
                        .padding(.horizontal)

                    // Summary card — requires SummarizationQueueStore and
                    // ModelManagerStore injected as environment objects by the
                    // window controller.
                    SummaryCardView(
                        recording: recording,
                        store: store,
                        activeSummarizerID: prefs.activeSummarizerID,
                        hasTranscript: hasTranscriptSource(recording),
                        onClearSummary: { id in
                            Task {
                                do {
                                    try await store.clearSummaryStatus(id: id)
                                    mutationFailure = nil
                                } catch {
                                    reportMutationFailure(.clearSummary(recording.displayTitle), error: error)
                                }
                            }
                        }
                    )
                    .padding(.horizontal)

                    if transcriptFindVisible {
                        transcriptFindBar(proxy: proxy)
                            .padding(.horizontal)
                    }

                    // Transcript text
                    transcriptBody(proxy: proxy)
                        .padding(.horizontal)
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(transcriptKeyboardShortcuts(proxy: proxy))
        }
        .navigationTitle(recording.displayTitle)
        // Reload transcript when the selection's recording row changes in the DB.
        .task(id: recording.wavPath) {
            await observeRecording(recording: recording)
            await loadInspectorSummaryData(for: recording)
        }
        .onChange(of: transcriptSearchText) { _, _ in
            transcriptSearchIndex = 0
        }
    }

    func inspectorSummaryChips(for recording: Recording) -> some View {
        let speakerCount = speakerIndices(for: recording).count
        let fileCount = [recording.wavPath, recording.txtPath, recording.jsonPath].compactMap(\.self).count
        return HStack(spacing: 8) {
            inspectorChip(
                title: inspectorPendingSuggestions.isEmpty ? "\(speakerCount) speakers" : "\(inspectorPendingSuggestions.count) speaker review",
                icon: inspectorPendingSuggestions.isEmpty ? "person.wave.2" : "person.crop.circle.badge.questionmark",
                tint: inspectorPendingSuggestions.isEmpty ? .secondary : .yellow
            )
            inspectorChip(
                title: "\(fileCount) files",
                icon: "folder",
                tint: .secondary
            )
            Spacer(minLength: 0)
        }
    }

    func inspectorChip(title: String, icon: String, tint: Color) -> some View {
        Button {
            inspectorOpen = true
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
    }

    @ViewBuilder
    func transcriptBody(proxy: ScrollViewProxy) -> some View {
        if let err = transcriptLoadError {
            Text(err)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !transcriptSegments.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(transcriptSegments) { seg in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(formatTimestamp(seconds: seg.startSec))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.10), in: Capsule())
                            Text(seg.speakerName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    Text(highlightedTranscriptText(seg.text, activeMatch: activeTranscriptMatch(for: seg.id)))
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(seg.id)
                    .padding(.vertical, activeTranscriptMatchSegmentID == seg.id ? 6 : 0)
                    .padding(.horizontal, activeTranscriptMatchSegmentID == seg.id ? 8 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(activeTranscriptMatchSegmentID == seg.id ? Color.accentColor.opacity(0.08) : Color.clear)
                    )
                }
            }
        } else if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Trimmed, not just `.isEmpty`: a transcript of a single newline
            // is not empty by that test, so the pane rendered a blank void
            // instead of the empty state that exists for exactly this case.
            EmptyStateView(
                icon: "doc.text.magnifyingglass",
                title: "No transcript available",
                subtitle: "Transcribe this recording to make the transcript searchable and editable."
            )
        } else {
            Text(highlightedTranscriptText(transcriptText, activeMatch: activeTranscriptMatch))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id("flat-transcript")
        }
    }

    func transcriptFindBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
            TextField("Find in transcript", text: $transcriptSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($transcriptSearchFocused)
                .onSubmit { jumpToNextTranscriptMatch(proxy: proxy) }
            Text(transcriptSearchStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            Button {
                jumpToPreviousTranscriptMatch(proxy: proxy)
            } label: {
                Label("Previous match", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSearchMatches.isEmpty)
            .help("Previous match")
            Button {
                jumpToNextTranscriptMatch(proxy: proxy)
            } label: {
                Label("Next match", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSearchMatches.isEmpty)
            .help("Next match")
            Divider()
                .frame(height: 18)
            Button {
                jumpToPreviousSpeakerBoundary(proxy: proxy)
            } label: {
                Label("Previous speaker", systemImage: "person.fill.turn.up.left")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSegments.isEmpty)
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .help("Previous speaker change (⌘↑)")
            Button {
                jumpToNextSpeakerBoundary(proxy: proxy)
            } label: {
                Label("Next speaker", systemImage: "person.fill.turn.down.right")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSegments.isEmpty)
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .help("Next speaker change (⌘↓)")
            Button {
                transcriptSearchText = ""
                transcriptFindVisible = false
            } label: {
                Label("Close find", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close find")
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    func transcriptKeyboardShortcuts(proxy: ScrollViewProxy) -> some View {
        HStack {
            Button("Find in transcript") {
                transcriptFindVisible = true
                transcriptSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button("Next speaker") {
                jumpToNextSpeakerBoundary(proxy: proxy)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Previous speaker") {
                jumpToPreviousSpeakerBoundary(proxy: proxy)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    var transcriptSearchQuery: String {
        transcriptSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var transcriptSearchMatches: [TranscriptSearchMatch] {
        let query = transcriptSearchQuery
        guard !query.isEmpty else { return [] }

        if !transcriptSegments.isEmpty {
            return transcriptSegments.flatMap { segment in
                TranscriptFind.matches(in: segment.text, query: query, segmentID: segment.id)
            }
        }

        return TranscriptFind.matches(in: transcriptText, query: query)
    }

    var transcriptSearchStatus: String {
        let matches = transcriptSearchMatches
        guard !transcriptSearchQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return "0/0" }
        return "\(min(transcriptSearchIndex + 1, matches.count))/\(matches.count)"
    }

    var activeTranscriptMatchSegmentID: UUID? {
        activeTranscriptMatch?.segmentID
    }

    var activeTranscriptMatch: TranscriptSearchMatch? {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(transcriptSearchIndex, matches.count - 1)]
    }

    func activeTranscriptMatch(for segmentID: UUID) -> TranscriptSearchMatch? {
        guard let match = activeTranscriptMatch, match.segmentID == segmentID else { return nil }
        return match
    }

    func jumpToNextTranscriptMatch(proxy: ScrollViewProxy) {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + 1) % matches.count
        scrollToTranscriptMatch(matches[transcriptSearchIndex], proxy: proxy)
    }

    func jumpToPreviousTranscriptMatch(proxy: ScrollViewProxy) {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + matches.count - 1) % matches.count
        scrollToTranscriptMatch(matches[transcriptSearchIndex], proxy: proxy)
    }

    func scrollToTranscriptMatch(_ match: TranscriptSearchMatch, proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if let segmentID = match.segmentID {
                proxy.scrollTo(segmentID, anchor: .center)
            } else {
                proxy.scrollTo("flat-transcript", anchor: .center)
            }
        }
    }

    func jumpToNextSpeakerBoundary(proxy: ScrollViewProxy) {
        guard let id = nextSpeakerBoundaryID(forward: true) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    func jumpToPreviousSpeakerBoundary(proxy: ScrollViewProxy) {
        guard let id = nextSpeakerBoundaryID(forward: false) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    func nextSpeakerBoundaryID(forward: Bool) -> UUID? {
        let boundaries = transcriptSegments.indices.dropFirst().compactMap { index -> UUID? in
            transcriptSegments[index].speaker == transcriptSegments[index - 1].speaker
                ? nil
                : transcriptSegments[index].id
        }
        guard !boundaries.isEmpty else { return transcriptSegments.first?.id }

        let activeID = activeTranscriptMatchSegmentID
        let activeIndex = activeID.flatMap { id in transcriptSegments.firstIndex { $0.id == id } } ?? 0

        if forward {
            return transcriptSegments[activeIndex...].dropFirst().first { segment in
                boundaries.contains(segment.id)
            }?.id ?? boundaries.first
        }

        return transcriptSegments[..<max(activeIndex, 1)].reversed().first { segment in
            boundaries.contains(segment.id)
        }?.id ?? boundaries.last
    }

    func highlightedTranscriptText(_ text: String, activeMatch: TranscriptSearchMatch?) -> AttributedString {
        let query = transcriptSearchQuery
        guard !query.isEmpty else { return AttributedString(text) }

        let highlighted = NSMutableAttributedString(string: text)
        for match in TranscriptFind.matches(in: text, query: query, segmentID: activeMatch?.segmentID) {
            let isActive = activeMatch?.range == match.range
            highlighted.addAttribute(
                .backgroundColor,
                value: NSColor.selectedTextBackgroundColor.withAlphaComponent(isActive ? 0.72 : 0.30),
                range: match.range
            )
            if isActive {
                highlighted.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            }
        }
        return AttributedString(highlighted)
    }

    func formatTimestamp(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds / 60) % 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

}
