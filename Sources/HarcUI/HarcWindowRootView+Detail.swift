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
                        .padding(.horizontal, HarcSpacing.lg)
                        .padding(.top, HarcSpacing.md)
                        .padding(.bottom, HarcSpacing.sm)
                }
            }
    }

    @ViewBuilder
    var detailBody: some View {
        libraryDetail
    }

    func mutationFailureBanner(_ failure: LibraryMutationFailure) -> some View {
        HStack(alignment: .top, spacing: HarcSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.harc(.failure))
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title)
                    .font(.harcCaption.weight(.semibold))
                Text(failure.message)
                    .font(.harcCaption)
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
        .padding(HarcSpacing.md)
        .background(Color.harc(.failure).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.harc(.failure).opacity(0.25), lineWidth: 1)
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
        case .live:
            // The in-progress recording is a real destination now, not a
            // fallback for having nothing selected. If it stops while
            // selected, the selection handoff in the root view moves to the
            // finished file; this branch only renders while capture is live.
            if recordingState.isRecording {
                LiveTranscriptPane(
                    recordingState: recordingState,
                    lastUpdateAge: bridge.activeCaptureStatus?.transcriptAgeText()
                )
            } else {
                ContentUnavailableView(
                    "Recording Finished",
                    systemImage: "waveform",
                    description: Text("The recording is being saved.")
                )
            }
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                detailTitleRow(recording: recording)

                WaveformPlayerView(
                    envelope: detailEnvelope,
                    audioURL: URL(fileURLWithPath: recording.wavPath),
                    model: playerModel
                )

                inspectorSummaryChips(for: recording)

                // Summary card — requires SummarizationQueueStore and
                // ModelManagerStore injected as environment objects by the
                // window controller. Scrolls internally past a bound so a
                // long summary can't push the transcript off screen, and
                // capped to the reading measure: comfortable prose is 60–75
                // characters, not 140.
                ScrollView {
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
                }
                .frame(maxWidth: 680, maxHeight: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                if transcriptFindVisible {
                    transcriptFindBar()
                        .frame(maxWidth: 680)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, HarcSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // The transcript, editable in place. This pane is the single
            // surface — the separate editor window, its second toolbar,
            // second find bar and hash-derived waveform are gone.
            transcriptEditorBody
        }
        .navigationTitle(recording.displayTitle)
        .background(transcriptKeyboardShortcuts())
        // Reload transcript when the selection's recording row changes in the DB.
        .task(id: recording.wavPath) {
            await observeRecording(recording: recording)
            await loadInspectorSummaryData(for: recording)
        }
        .onChange(of: transcriptSearchText) { _, _ in
            transcriptSearchIndex = 0
            syncFindHighlight()
        }
        .onChange(of: editorText) { _, _ in
            editorTextDidChange()
        }
        .onReceive(playerModel.$currentTime) { time in
            updatePlaybackHighlight(at: time)
        }
    }

    /// Title as an editable field — the rename affordance the Library never
    /// had (the view-model API existed with no caller; the retired editor
    /// window was the only place a title could be changed).
    func detailTitleRow(recording: Recording) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
            TextField("Untitled", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { commitTitle(for: recording) }
            Spacer(minLength: 8)
            if let error = editorSaveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.harcCaption)
                    .foregroundStyle(Color.harc(.attention))
                    .lineLimit(1)
                    .help(error)
            } else if editorDirty {
                Text("Editing…")
                    .font(.harcCaption)
                    .foregroundStyle(.tertiary)
            } else if lastAutosaveAt != nil {
                // The quiet "Saved" — no button, no dirty dot, no
                // save-on-close alert. The document regenerates after every
                // edit; the UI just says so.
                Text("Saved")
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var transcriptEditorBody: some View {
        Group {
            if let err = transcriptLoadError, editorText.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No transcript available",
                    subtitle: err
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No transcript available",
                    subtitle: "Transcribe this recording to make the transcript searchable and editable."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The reading column: capped at 680pt and centered once the
                // pane is wider than that. The single cheapest legibility
                // win in the app, per the audit.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TranscriptDetailEditor(
                        text: $editorText,
                        highlightRange: editorHighlight,
                        onCommandClick: { offset in seekToWord(atCharOffset: offset) }
                    )
                    .frame(maxWidth: 680)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Editing lifecycle

    func editorTextDidChange() {
        guard let doc = detailDocument else { return }
        guard editorText != doc.initialText || editorDirty else { return }
        editorDirty = true
        // Word ranges no longer line up once the text shifts — stop
        // highlighting rather than highlight the wrong words. This is the
        // subtle version of the old "timestamps approximate" banner.
        editorHighlight = nil
        scheduleAutosave()
    }

    /// Autosave on pause: ~2s after the last keystroke. ⌘S flushes
    /// immediately; switching selection flushes synchronously.
    func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [text = editorText] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await performAutosave(text: text)
        }
    }

    func performAutosave(text: String) async {
        guard let doc = detailDocument, editorDirty else { return }
        do {
            _ = try doc.save(editedText: text)
            if let id = doc.recordingID {
                try await store.updateTranscriptText(id: id, text: text)
            }
            editorDirty = (editorText != text)
            editorSaveError = nil
            lastAutosaveAt = Date()
        } catch {
            editorSaveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Synchronous flush used when the selection is about to change — the
    /// debounce must not lose the last two seconds of typing.
    func flushPendingDetailEdits(previousSelection: LibrarySelection?) {
        autosaveTask?.cancel()
        guard case .recording(let wavPath) = previousSelection,
              let doc = detailDocument, editorDirty else { return }
        let text = editorText
        let recID = doc.recordingID
        Task.detached { [store] in
            _ = try? doc.save(editedText: text)
            if let recID {
                try? await store.updateTranscriptText(id: recID, text: text)
            }
            _ = wavPath
        }
        // Commit any pending title edit through the same exit.
        if let rec = libraryVM.recordings.first(where: { $0.wavPath == wavPath }) {
            commitTitle(for: rec)
        }
    }

    func commitTitle(for recording: Recording) {
        guard let id = recording.id else { return }
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = recording.title ?? ""
        guard trimmed != current else { return }
        Task {
            try? await libraryVM.rename(id: id, title: trimmed.isEmpty ? nil : trimmed)
        }
    }

    // MARK: - Seek + playback highlight

    func seekToWord(atCharOffset offset: Int) {
        guard let doc = detailDocument, !editorDirty,
              let entry = doc.wordIndex.wordAt(charOffset: offset) else { return }
        Task {
            await playerModel.seek(to: Double(entry.word.startMs) / 1000.0, andPlay: true)
        }
    }

    func updatePlaybackHighlight(at time: Double) {
        guard playerModel.isPlaying, !editorDirty, transcriptSearchQuery.isEmpty,
              let doc = detailDocument, !doc.wordIndex.entries.isEmpty else { return }
        let entry = doc.wordIndex.wordAt(timeMs: Int(time * 1000))
        if entry?.range != editorHighlight {
            editorHighlight = entry?.range
        }
    }

    /// Speakers as content, not chips. "1 speaker" and "3 files" were
    /// bordered buttons tinted like tags; the file count was a storage
    /// implementation detail promoted to an affordance — the user did not
    /// create three files, Harc did (the inspector still lists them). Named
    /// avatars carry the real information and click through to renaming.
    func inspectorSummaryChips(for recording: Recording) -> some View {
        HStack(spacing: HarcSpacing.sm) {
            if !inspectorPendingSuggestions.isEmpty {
                Button {
                    inspectorOpen = true
                } label: {
                    Label(
                        Pluralize.count(inspectorPendingSuggestions.count, "speaker") + " to review",
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                    .font(.harcCaption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.harc(.attention))
            }
            ForEach(speakerIndices(for: recording), id: \.self) { index in
                let name = resolvedSpeakerLabels[index] ?? "Speaker \(index + 1)"
                Button {
                    inspectorOpen = true
                } label: {
                    HStack(spacing: HarcSpacing.xs) {
                        PersonAvatar(displayName: name, size: 18)
                        Text(name)
                            .font(.harcCaption)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Rename speakers in the inspector")
            }
            Spacer(minLength: 0)
        }
    }


    @ViewBuilder
    // MARK: - Find (flat text — the editor applies the highlight)

    func transcriptFindBar() -> some View {
        HStack(spacing: HarcSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.secondary)
            TextField("Find in transcript", text: $transcriptSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($transcriptSearchFocused)
                .onSubmit { jumpToNextTranscriptMatch() }
            Text(transcriptSearchStatus)
                .font(.harcCaption.monospacedDigit())
                .foregroundStyle(Color.secondary)
                .frame(minWidth: 58, alignment: .trailing)
            Button {
                jumpToPreviousTranscriptMatch()
            } label: {
                Label("Previous match", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSearchMatches.isEmpty)
            .help("Previous match")
            Button {
                jumpToNextTranscriptMatch()
            } label: {
                Label("Next match", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(transcriptSearchMatches.isEmpty)
            .help("Next match")
            Divider()
                .frame(height: 18)
            Button {
                jumpToSpeakerBoundary(forward: false)
            } label: {
                Label("Previous speaker", systemImage: "person.fill.turn.up.left")
            }
            .labelStyle(.iconOnly)
            .disabled(speakerBoundaries.isEmpty)
            .help("Previous speaker change (⌘↑)")
            Button {
                jumpToSpeakerBoundary(forward: true)
            } label: {
                Label("Next speaker", systemImage: "person.fill.turn.down.right")
            }
            .labelStyle(.iconOnly)
            .disabled(speakerBoundaries.isEmpty)
            .help("Next speaker change (⌘↓)")
            Button {
                transcriptSearchText = ""
                transcriptFindVisible = false
                editorHighlight = nil
            } label: {
                Label("Close find", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Close find")
        }
        .padding(HarcSpacing.md)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    func transcriptKeyboardShortcuts() -> some View {
        HStack {
            Button("Find in transcript") {
                transcriptFindVisible = true
                transcriptSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            Button("Save transcript now") {
                autosaveTask?.cancel()
                Task { await performAutosave(text: editorText) }
            }
            .keyboardShortcut("s", modifiers: [.command])
            Button("Next speaker") {
                jumpToSpeakerBoundary(forward: true)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Previous speaker") {
                jumpToSpeakerBoundary(forward: false)
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
        return TranscriptFind.matches(in: editorText, query: query)
    }

    var transcriptSearchStatus: String {
        let matches = transcriptSearchMatches
        guard !transcriptSearchQuery.isEmpty else { return "" }
        guard !matches.isEmpty else { return "0/0" }
        return "\(min(transcriptSearchIndex + 1, matches.count))/\(matches.count)"
    }

    var activeTranscriptMatch: TranscriptSearchMatch? {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(transcriptSearchIndex, matches.count - 1)]
    }

    func syncFindHighlight() {
        editorHighlight = activeTranscriptMatch?.range
    }

    func jumpToNextTranscriptMatch() {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex + 1) % matches.count
        syncFindHighlight()
    }

    func jumpToPreviousTranscriptMatch() {
        let matches = transcriptSearchMatches
        guard !matches.isEmpty else { return }
        transcriptSearchIndex = (transcriptSearchIndex - 1 + matches.count) % matches.count
        syncFindHighlight()
    }

    /// Speaker turns in flat text: line starts that look like "Name: ".
    /// Computed at load; jumping moves the highlight (and the scroll) to the
    /// start of the neighboring turn relative to the current highlight.
    static func speakerTurnOffsets(in text: String) -> [Int] {
        let ns = text as NSString
        var offsets: [Int] = []
        var lineStart = 0
        while lineStart < ns.length {
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            if let colon = line.firstIndex(of: ":"),
               line.distance(from: line.startIndex, to: colon) <= 40,
               !line[..<colon].trimmingCharacters(in: .whitespaces).isEmpty {
                offsets.append(lineStart)
            }
            lineStart = lineEnd
        }
        return offsets
    }

    func jumpToSpeakerBoundary(forward: Bool) {
        guard !speakerBoundaries.isEmpty else { return }
        let current = editorHighlight?.location ?? 0
        let target: Int?
        if forward {
            target = speakerBoundaries.first { $0 > current }
        } else {
            target = speakerBoundaries.last { $0 < current }
        }
        guard let target else { return }
        // Highlight the turn's leading line briefly-ish (until the next
        // navigation) so the jump is visible; length to end of "Name:".
        let ns = editorText as NSString
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                        for: NSRange(location: target, length: 0))
        editorHighlight = NSRange(location: target, length: max(1, min(contentsEnd - target, 60)))
    }


    func formatTimestamp(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds / 60) % 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

}
