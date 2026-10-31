import SwiftUI
import Foundation
import HarcStore
import HarcExport
import HarcClient
import HarcCore
import HarcPresenceUI
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
        VStack(spacing: 0) {
            TideLibrarySearchField(text: $libraryVM.searchText, focusToken: librarySearchFocusToken)
            .frame(width: 310, height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(height: 52)

            libraryDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { HarcTideBackground() }
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
        case .session(let id):
            SessionDetailView(
                sessionID: id,
                store: store,
                onSelectRecording: { rec in
                    selection = .recording(wavPath: rec.wavPath)
                },
                onSummarize: onSummarizeSession,
                onDissolve: { session in
                    pendingDissolveSession = session
                }
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
            VStack(alignment: .leading, spacing: 12) {
                HarcTideConditions {
                    if let endedAt = recording.endedAt {
                        Text(Self.formatDuration(from: recording.startedAt, to: endedAt))
                    }
                    let speakerCount = speakerIndices(for: recording).count
                    if speakerCount > 0 {
                        Text(Pluralize.count(speakerCount, "speaker"))
                    }
                    if let actions = recording.actionItemsMarkdown,
                       !SummaryParser.parseActionItems(actions).isEmpty {
                        let parsed = SummaryParser.parseActionItems(actions)
                        Text(Pluralize.count(parsed.count, "action"))
                    }
                    Label("On this Mac", systemImage: "desktopcomputer")
                }
                .frame(maxWidth: .infinity)
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        detailTitleRow(recording: recording)
                        HStack(spacing: 5) {
                            Text(recording.startedAt, format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
                            if let endedAt = recording.endedAt {
                                Text("–")
                                Text(endedAt, format: .dateTime.hour().minute())
                            }
                            Text("·")
                            Label(libraryVM.originLabel(for: recording), systemImage: "record.circle")
                                .textSelection(.enabled)
                                .accessibilityIdentifier("harc.recording.origin")
                        }
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(formatTimestamp(seconds: Int(playerModel.currentTime)))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        if let endedAt = recording.endedAt {
                            Text("of \(Self.formatDuration(from: recording.startedAt, to: endedAt))")
                                .font(.harcCaption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if recording.captureIntegrity.hasIssues || !recording.captureDiscontinuities.isEmpty {
                    Label("Some audio may be missing. Review capture interruptions before relying on this recording.", systemImage: "exclamationmark.triangle")
                        .font(.harcCaption)
                        .foregroundStyle(Color.harc(.attention))
                        .accessibilityIdentifier("harc.recording.captureIntegrityWarning")
                }

                WaveformPlayerView(
                    envelope: detailEnvelope,
                    audioURL: URL(fileURLWithPath: recording.wavPath),
                    speakerSegments: detailDocument?.speakers ?? [],
                    model: playerModel
                )

                if transcriptFindVisible {
                    transcriptFindBar()
                        .frame(maxWidth: .infinity)
                }

                if let warning = detailDocument?.overlapWarning, !editorText.contains(warning) {
                    Label(warning, systemImage: "person.2.wave.2")
                        .font(.harcCaption)
                        .foregroundStyle(Color.harc(.attention))
                        .accessibilityIdentifier("harc.transcript.overlap-warning")
                }

                vocabularySuggestionBar
            }
            // The header and transcript share the available detail width so
            // the document responds continuously as the split view or window
            // is resized.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 16)

            // The transcript, editable in place. This pane is the single
            // surface — the separate editor window, its second toolbar,
            // second find bar and hash-derived waveform are gone.
            GeometryReader { geometry in
                if geometry.size.width >= 760 { // token-exempt: two-column detail breakpoint.
                    HStack(alignment: .top, spacing: 18) {
                        transcriptEditorBody
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        detailInsights(recording: recording)
                            .frame(width: 350) // token-exempt: Tide insight column.
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 8) {
                        transcriptEditorBody
                        detailInsights(recording: recording)
                            .frame(maxHeight: 150)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .navigationTitle(recording.displayTitle)
        .background(transcriptKeyboardShortcuts())
        // Reload transcript when the selection's recording row changes in the DB.
        // Two child tasks, not two awaits: `observeRecording` iterates a DB
        // observation stream that never finishes, so anything sequenced after
        // it is dead code — the summary/suggestions load silently never ran,
        // which starved the "N speakers to review" chip whenever the
        // inspector was closed.
        .task(id: recording.wavPath) {
            // A restored selection can arrive before the observed library
            // rows. Its selection-change handler then has no document to
            // load; initialize when the actual detail first becomes available.
            if detailDocument == nil {
                loadTranscript()
                await loadEnvelope()
                await loadResolvedLabels()
            }
            async let observation: Void = observeRecording(recording: recording)
            async let inspectorData: Void = loadInspectorSummaryData(for: recording)
            _ = await (observation, inspectorData)
        }
        .onChange(of: transcriptSearchText) { _, _ in
            transcriptSearchIndex = 0
            syncFindHighlight()
        }
        .onChange(of: editorText) { _, _ in
            editorTextDidChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            flushPendingDetailEditsForTermination()
        }
        .onReceive(playerModel.$currentTime) { time in
            updatePlaybackHighlight(at: time)
        }
    }

    private func detailInsights(recording: Recording) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarcSpacing.md) {
                SummaryCardView(
                    recording: recording,
                    store: store,
                    activeSummarizerID: prefs.activeSummarizerID,
                    hasTranscript: hasTranscriptSource(recording),
                    showActionItems: false,
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
                HStack(alignment: .top, spacing: 10) {
                    if let markdown = recording.actionItemsMarkdown?.harcTrimmedNonEmpty {
                        tideActionsCard(markdown)
                            .frame(maxWidth: .infinity)
                    }
                    if let speakers = detailDocument?.speakers, !speakers.isEmpty {
                        tideTalkTimeCard(speakers)
                            .frame(maxWidth: .infinity)
                    }
                }
                if recording.notesMarkdown?.harcTrimmedNonEmpty != nil || showTideNotes {
                    if let recID = recording.id {
                        NotesCardView(
                            itemID: recID,
                            notes: recording.notesMarkdown,
                            onSave: { [store] text in
                                try await store.updateNotes(id: recID, markdown: text)
                            }
                        )
                    }
                } else if recording.id != nil {
                    Button("Add notes") { showTideNotes = true }
                        .font(.harcCaption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(HarcSpacing.md)
        }
        .background(.clear)
    }

    private func tideInsightCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.harcCaption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func tideActionsCard(_ markdown: String) -> some View {
        let actions = SummaryParser.parseActionItems(markdown)
        let needsReview = actions.isEmpty && markdown.lowercased() != "_none identified._"
        return tideInsightCard(title: "Action items", icon: "checklist") {
            Button {
                showTideActions = true
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(needsReview ? "—" : "\(actions.count)")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text(needsReview ? "Review source" : actions.count == 1 ? "View action" : "View actions")
                        .font(.harcCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTideActions) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Action items").font(.headline)
                        if actions.isEmpty {
                            Text(.init(markdown))
                        } else {
                            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                                Label(action.text, systemImage: action.done ? "checkmark.circle.fill" : "circle")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(width: 320, height: 220)
            }
        }
    }

    private func tideTalkTimeCard(_ segments: [SpeakerSegment]) -> some View {
        let durations = Dictionary(grouping: segments, by: \.speaker)
            .mapValues { values in
                values.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            }
        let total = max(1, durations.values.reduce(0, +))
        return tideInsightCard(title: "Talk time", icon: "person.2.wave.2") {
            ForEach(durations.keys.sorted(), id: \.self) { index in
                let name = resolvedSpeakerLabels[index] ?? "Speaker \(index + 1)"
                HStack(spacing: 5) {
                    Text(name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int((Double(durations[index, default: 0]) / Double(total) * 100).rounded()))%")
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    Capsule()
                        .fill(tideSpeakerColor(index).opacity(0.8))
                        .frame(width: max(3, geometry.size.width * CGFloat(durations[index, default: 0]) / CGFloat(total)))
                }
                .frame(height: 6)
                .font(.harcCaption)
            }
        }
    }

    private func tideSpeakerColor(_ index: Int) -> Color {
        let colors: [Color] = [HarcTideStyle.cyan, .purple, .orange, .teal, .green, .pink]
        return colors[abs(index) % colors.count]
    }

    /// Title as an editable field — the rename affordance the Library never
    /// had (the view-model API existed with no caller; the retired editor
    /// window was the only place a title could be changed).
    func detailTitleRow(recording: Recording) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HarcSpacing.sm) {
            // The suggested title as the placeholder, not "Untitled": the
            // window title bar and sidebar row already show the suggestion
            // via displayTitle, and a field that says "Untitled" under a
            // titled window reads as two surfaces disagreeing about the
            // recording's name.
            TextField(recording.displayTitle, text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 29, weight: .bold, design: .rounded)) // token-exempt: Tide's primary title.
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
            } else if editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !editorDirty, detailDocument?.initialText.isEmpty != false {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No transcript available",
                    subtitle: "Transcribe this recording to make the transcript searchable and editable."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptDetailEditor(
                    text: $editorText,
                    highlightRange: editorHighlight,
                    onCommandClick: { offset in seekToWord(atCharOffset: offset) },
                    timestampForOffset: { offset in
                        // Dirty edits shift offsets under the index —
                        // no stamp beats a wrong stamp.
                        guard !editorDirty else { return nil }
                        return detailDocument?.wordIndex.wordAt(charOffset: offset)?.word.startMs
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // AppKit rulers may otherwise draw outside the frame
                // SwiftUI assigns during split-view relayout, producing
                // a full-height hairline through the header.
                .clipped()
            }
        }
    }

    // MARK: - Editing lifecycle

    func editorTextDidChange() {
        guard let doc = detailDocument else { return }
        // Undo can return to the initially loaded text after another edit has
        // already autosaved. Compare with the persisted text, not the load
        // snapshot, so that undo is itself saved.
        guard editorText != (lastSavedEditorText ?? doc.initialText) || editorDirty else { return }
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
            offerVocabularyCorrections(newText: text)
        } catch {
            editorSaveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Corrections should feed the vocabulary (#101): diff the edit against
    /// the last saved text, offer "Always replace X → Y" for
    /// proper-noun-ish fixes. One click adds; nothing is ever added
    /// silently; dismissals hold for the session.
    func offerVocabularyCorrections(newText: String) {
        defer { lastSavedEditorText = newText }
        guard let old = lastSavedEditorText, old != newText else { return }
        let existing = Set(prefs.vocabulary.entries.map { $0.from.lowercased() })
        let fresh = VocabularyCorrectionDetector.detect(old: old, new: newText)
            .filter { !existing.contains($0.from.lowercased()) }
            .filter { !dismissedVocabPairs.contains($0) }
        guard !fresh.isEmpty else { return }
        var merged = vocabCandidates
        for candidate in fresh where !merged.contains(candidate) {
            merged.append(candidate)
        }
        vocabCandidates = merged
    }

    func addVocabularyCandidate(_ candidate: VocabularyCorrectionDetector.Candidate) {
        var vocab = prefs.vocabulary
        vocab.entries.append(VocabularyEntry(from: candidate.from, to: candidate.to))
        prefs.vocabulary = vocab
        vocabCandidates.removeAll { $0 == candidate }
    }

    func dismissVocabularyCandidate(_ candidate: VocabularyCorrectionDetector.Candidate) {
        dismissedVocabPairs.insert(candidate)
        vocabCandidates.removeAll { $0 == candidate }
    }

    @ViewBuilder
    var vocabularySuggestionBar: some View {
        if let candidate = vocabCandidates.first {
            HStack(spacing: HarcSpacing.sm) {
                Image(systemName: "character.book.closed")
                    .foregroundStyle(.secondary)
                Text("Always replace \u{201C}\(candidate.from)\u{201D} with \u{201C}\(candidate.to)\u{201D} in future transcripts?")
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Add") { addVocabularyCandidate(candidate) }
                    .buttonStyle(.link)
                    .font(.harcCaption)
                Button("No Thanks") { dismissVocabularyCandidate(candidate) }
                    .buttonStyle(.link)
                    .font(.harcCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
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

    /// ⌘Q inside the 2 s debounce used to drop the edit on the floor: the
    /// on-screen state promised a save that never ran. At termination the
    /// async flush shape is useless — a detached Task doesn't outlive the
    /// process — so this one blocks: the OKF file save is synchronous, and
    /// the DB write gets a bounded wait. Blocking the main thread for up to
    /// a few seconds during quit is the correct trade against losing text.
    func flushPendingDetailEditsForTermination() {
        autosaveTask?.cancel()
        guard let doc = detailDocument, editorDirty else { return }
        let text = editorText
        _ = try? doc.save(editedText: text)
        if let id = doc.recordingID {
            let done = DispatchSemaphore(value: 0)
            Task.detached { [store] in
                try? await store.updateTranscriptText(id: id, text: text)
                done.signal()
            }
            _ = done.wait(timeout: .now() + 3)
        }
        editorDirty = false
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
