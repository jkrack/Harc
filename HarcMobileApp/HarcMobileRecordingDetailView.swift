import HarcClientStore
import HarcClientTransport
import HarcDomain
import HarcPresenceUI
import SwiftUI
import UIKit

private struct HarcNewRecordingActionKey: EnvironmentKey {
  static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
  var harcNewRecording: @MainActor @Sendable () -> Void {
    get { self[HarcNewRecordingActionKey.self] }
    set { self[HarcNewRecordingActionKey.self] = newValue }
  }
}

/// One stable surface, whether opened immediately after capture or from Library.
/// Local playback is never replaced when the matching Host projection arrives.
struct HarcMobileRecordingDetailView: View {
  @Environment(HarcMobileAppModel.self) private var model
  @Environment(\.harcNewRecording) private var newRecording
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dismiss) private var dismiss
  let reference: HarcMobileRecordingReference
  private let initialLocal: HarcMobileLocalRecording?
  private let initialHost: LibraryRecordingSummary?
  let storageExhausted: Bool
  private let done: (() -> Void)?
  private enum LeaveAction { case newRecording, done, back }
  @State private var pendingLeave: LeaveAction?
  @State private var confirmsDiscard = false
  @State private var announcedSummary = false
  @State private var announcedTranscript = false
  @State private var speakerDrafts: [UInt32: HarcMobileRecordingTextDraft] = [:]
  private enum DetailSection: String, CaseIterable {
    case summary = "Summary"
    case transcript = "Transcript"
    case notes = "Notes"
  }
  @State private var selectedSection: DetailSection = .summary
  @State private var detail: LibraryRecordingDetail?
  @State private var errorMessage: String?
  @State private var titleDraft = HarcMobileRecordingTextDraft()
  @State private var tagsDraft = HarcMobileRecordingTextDraft()
  @State private var notesDraft = HarcMobileRecordingTextDraft()
  @State private var newSpeakerIndex = ""
  @State private var newSpeakerName = ""
  @State private var mutationMessage: String?
  @State private var isSavingMetadata = false
  @State private var localAudio: HarcMobileLocalRecordingAudioController?
  @State private var hostAudio: HarcMobileRecordingAudioController?
  @State private var retainedLocal: HarcMobileLocalRecording?
  @State private var showsExport = false
  @State private var showsCopyConfirmation = false
  @State private var didCopyPrompt = false
  @State private var detailRequestGeneration = 0

  init(
    recording: HarcMobileLocalRecording, storageExhausted: Bool = false, done: (() -> Void)? = nil
  ) {
    reference = .origin(recording.originID)
    initialLocal = recording
    initialHost = nil
    self.storageExhausted = storageExhausted
    self.done = done
    _retainedLocal = State(initialValue: recording)
    _localAudio = State(
      initialValue: HarcMobileLocalRecordingAudioController(url: recording.masterFileURL))
  }

  init(coordinator: HarcMobileLibraryCoordinator, summary: LibraryRecordingSummary) {
    reference =
      summary.originID.map(HarcMobileRecordingReference.origin)
      ?? .canonical(summary.canonicalID)
    initialLocal = nil
    initialHost = summary
    storageExhausted = false
    done = nil
  }

  private var resolved: HarcMobileResolvedRecording {
    var host = model.libraryCoordinator?.recordings ?? []
    if let initialHost, !host.contains(where: { $0.canonicalID == initialHost.canonicalID }) {
      host.append(initialHost)
    }
    return reference.resolve(
      local: model.transferCoordinator?.localRecordings ?? [],
      host: host, fallbackLocal: retainedLocal ?? initialLocal)
  }

  private var currentSummary: LibraryRecordingSummary? {
    if let detail, let host = resolved.host {
      return detail.summary.revision.rawValue >= host.revision.rawValue ? detail.summary : host
    }
    return detail?.summary ?? resolved.host
  }
  private var title: String {
    for candidate in [currentSummary?.title, currentSummary?.suggestedTitle] {
      if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return candidate
      }
    }
    return resolved.local.map(HarcMobileUnifiedLibrary.localTitle) ?? "Recording"
  }
  private var startedAt: Date? { resolved.local?.startedAt ?? currentSummary?.startedAt }
  private var recordingDuration: TimeInterval {
    resolved.local?.duration ?? Double(currentSummary?.canonicalAudio.totalFrames ?? 0) / 16_000
  }
  private var captureBusy: Bool {
    guard let state = model.captureCoordinator?.state else { return true }
    return !HarcMobilePostRecordingDecision.canStartNewRecording(state: state)
  }
  private var libraryIsOffline: Bool {
    if errorMessage != nil { return true }
    switch model.hostHealthCoordinator?.status {
    case .unpaired, .unavailable, .pairingRepairRequired, .none: return true
    default: break
    }
    guard let coordinator = model.libraryCoordinator else { return true }
    switch coordinator.state {
    case .offline, .failed, .cancelled, .unpaired: return true
    default: return false
    }
  }

  private var isPartial: Bool {
    storageExhausted || resolved.local?.finalizationReason == .storageExhausted
  }
  private var hasUnsavedEdits: Bool {
    titleDraft.hasUnsavedChanges || tagsDraft.hasUnsavedChanges || notesDraft.hasUnsavedChanges
      || speakerDrafts.values.contains(where: \.hasUnsavedChanges)
      || !newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var presentation: HarcMobileRecordingDetailPresentation {
    .make(
      recording: .init(local: resolved.local, host: currentSummary),
      hostHealth: model.hostHealthCoordinator?.status ?? .unpaired,
      libraryIsOffline: libraryIsOffline, summary: detail?.summaryMarkdown,
      partialRecording: isPartial)
  }

  var body: some View {
    VStack(spacing: 0) {
      detailList
      newRecordingFooter
    }
    .navigationTitle("Recording")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(done != nil || hasUnsavedEdits)
    .interactiveDismissDisabled(hasUnsavedEdits)
    .toolbar(.hidden, for: .tabBar)
    .background { HarcTideBackground() }
    .toolbar {
      if done != nil {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { requestLeave(.done) }
            .accessibilityIdentifier("harc.mobile.detail.done")
        }
      } else if hasUnsavedEdits {
        ToolbarItem(placement: .topBarLeading) {
          Button("Back", systemImage: "chevron.left") { requestLeave(.back) }
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button(didCopyPrompt ? "Copied" : "Copy for Prompt") { showsCopyConfirmation = true }
            .disabled(detail == nil)
          if resolved.local != nil {
            Button("Export audio…", systemImage: "square.and.arrow.up") {
              localAudio?.stop()
              showsExport = true
            }.disabled(captureBusy)
          }
          Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadDetail() } }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Recording actions")
      }
    }
    .confirmationDialog(
      "Discard unsaved edits?", isPresented: $confirmsDiscard, titleVisibility: .visible
    ) {
      Button("Discard edits", role: .destructive) { performLeave() }
      Button("Keep editing", role: .cancel) { pendingLeave = nil }
    } message: {
      Text("Your recording is saved. Save your text changes before leaving to keep them.")
    }
    .onChange(of: mutationMessage) { _, message in
      if let message, UIAccessibility.isVoiceOverRunning {
        UIAccessibility.post(notification: .announcement, argument: message)
      }
    }
    .confirmationDialog(
      "Copy recording text?", isPresented: $showsCopyConfirmation, titleVisibility: .visible
    ) {
      Button("Copy to this iPhone") { copyForPrompt() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The title, summary, actions, notes, and transcript will be copied to this iPhone’s clipboard for five minutes. Pasting into another app shares that text outside your paired Mac and iPhone."
      )
    }
    .sheet(isPresented: $showsExport) {
      if let local = resolved.local {
        HarcMobileLocalRecordingExportView(recording: local, isPresented: $showsExport)
      }
    }
    .refreshable { await loadDetail() }
    .task {
      preparePlayback()
      await localAudio?.prepare()
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      // Visible-only refresh with bounded backoff, including long processing.
      // Audio playback and edits are owned independently of these snapshots.
      var attempt = 0
      while !Task.isCancelled {
        await loadDetail()
        let delay = [2, 3, 5, 8, 13, 20, 30][min(attempt, 6)]
        attempt = min(attempt + 1, 6)
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      }
    }
    .onDisappear {
      detailRequestGeneration += 1
      localAudio?.stop()
      hostAudio?.stopAndRelease()
    }
  }

  private var detailList: some View {
    List {
      Section {
        recordingHeader.listRowSeparator(.hidden)
        playbackControls
      }
      Section { sectionPicker }
      if currentSummary != nil {
        Section {
          Label(presentation.processingTitle, systemImage: presentation.processingSymbol)
            .font(.subheadline.weight(.medium))
          Text(presentation.processingMessage).font(.footnote).foregroundStyle(.secondary)
        }
      }
      if let detail, let coordinator = model.libraryCoordinator {
        hostContent(detail, coordinator: coordinator)
      } else {
        Section(selectedSection.rawValue) { pendingContent }
      }
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "wifi.slash")
            .font(.footnote).foregroundStyle(.secondary)
          Button("Refresh") { Task { await loadDetail() } }
        }
      }
    }
    .scrollContentBackground(.hidden)
    .accessibilityIdentifier("harc.mobile.detail")
  }

  // Keep the primary action outside List's scrolling compositing surface.
  private var newRecordingFooter: some View {
    Button(action: { requestLeave(.newRecording) }) {
      HStack(spacing: 10) {
        Image(systemName: "mic.fill")
        Text("New recording").fixedSize(horizontal: false, vertical: true)
      }
      .font(.headline)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 16).padding(.vertical, 16)
      .foregroundStyle(HarcTideStyle.onAccent)
      .background(HarcMobilePalette.action, in: Capsule())
      .opacity(captureBusy ? 0.5 : 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("New recording")
    .disabled(captureBusy)
    .accessibilityIdentifier("harc.mobile.detail.newRecording")
    .padding(.horizontal, 20).padding(.vertical, 10)
    .background(.regularMaterial)
  }

  private var recordingHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.system(.title2, design: .rounded, weight: .bold))
        .accessibilityIdentifier("harc.mobile.detail.title")
        .accessibilityAddTraits(.isHeader)
      if let startedAt {
        Text(
          startedAt.formatted(date: .abbreviated, time: .shortened) + " · "
            + HarcMobileRecordingFormatting.duration(recordingDuration)
        )
        .font(.subheadline).foregroundStyle(.secondary)
      }
      if resolved.local != nil {
        Label("Saved on this iPhone", systemImage: "checkmark.shield.fill")
          .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
      }
      if currentSummary != nil || resolved.local?.transferState == .committed {
        Text(presentation.macAudioMessage).font(.caption).foregroundStyle(.secondary)
      }
      if isPartial {
        Label(
          "Recording stopped when storage ran out. Harc saved the durable portion. Check free space before recording again.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.primary)
      } else if detail?.captureNeedsReview == nil, let local = resolved.local,
        !local.discontinuities.isEmpty
      {
        Label(
          "This recording was interrupted. Review the audio before relying on it.",
          systemImage: "waveform.badge.exclamationmark"
        )
        .font(.footnote).foregroundStyle(.primary)
      }
      transferStatus
    }.padding(.vertical, 6)
  }

  @ViewBuilder private var transferStatus: some View {
    if let local = resolved.local, currentSummary?.canonicalAudio.availability != .available {
      switch local.transferState {
      case .localOnly:
        Text("Waiting to send to your Mac").font(.footnote).foregroundStyle(.secondary)
      case .transferring:
        Label("Sending to your Mac…", systemImage: "arrow.up.circle")
          .font(.footnote).foregroundStyle(.secondary)
      case .committed:
        Text("Received by your Mac").font(.footnote).foregroundStyle(.secondary)
      case .retryNeeded:
        Text("Saved here. Sending needs another try.").font(.footnote)
        Button("Retry sending") { model.transferCoordinator?.retry(recordingUUID: local.id) }
          .disabled(model.transferCoordinator?.isCodecQualifiedForTransfers != true)
      case .securityBlocked:
        Label(
          "Mac access needs review. Your audio remains on this iPhone.", systemImage: "lock.shield"
        )
        .font(.footnote).foregroundStyle(.primary)
      }
    }
  }

  private var pendingContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(pendingTitle, systemImage: selectedSection == .notes ? "note.text" : "text.alignleft")
        .font(.headline)
      Text(pendingMessage).font(.subheadline).foregroundStyle(.secondary)
      if localAudio != nil, !isPartial {
        Text("You can listen now or start another recording.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 12)
      .accessibilityIdentifier("harc.mobile.detail.pending")
  }

  private var pendingTitle: String {
    if selectedSection == .notes { return "Notes" }
    if currentSummary == nil || currentSummary?.processing.state == .ready {
      return selectedSection == .summary
        ? "Summary not available yet" : "Transcript not available yet"
    }
    return presentation.processingTitle
  }
  private var pendingMessage: String {
    if selectedSection == .notes {
      return "Notes and title editing become available when this recording appears on your Mac."
    }
    if currentSummary?.processing.state == .ready, !libraryIsOffline {
      return selectedSection == .summary
        ? "A summary will appear here if one is generated on your Mac."
        : "No transcript is available from your Mac yet."
    }
    return presentation.processingMessage
  }

  private func preparePlayback() {
    if localAudio == nil, hostAudio == nil, let local = resolved.local {
      retainedLocal = local
      localAudio = HarcMobileLocalRecordingAudioController(url: local.masterFileURL)
    }
    if localAudio == nil, hostAudio == nil, let coordinator = model.libraryCoordinator,
      let summary = currentSummary, summary.canonicalAudio.availability == .available
    {
      hostAudio = HarcMobileRecordingAudioController(coordinator: coordinator, summary: summary)
    }
  }

  private var playbackControls: some View {
    TimelineView(
      .animation(
        minimumInterval: reduceMotion ? 0.25 : 1.0 / 15,
        paused: scenePhase != .active)
    ) { _ in
      VStack(spacing: 16) {
        if !envelope.isEmpty {
          HarcTideEnergyTrace(
            samples: envelope, playbackProgress: playbackTime / max(1, playbackDuration)
          )
          .frame(height: 72)
          .padding(10)
          .background(
            HarcTideStyle.deepBlue, in: RoundedRectangle(cornerRadius: HarcTideStyle.plotRadius)
          )
          .accessibilityLabel("Recorded audio energy")
        }
        HStack {
          Text(Duration.seconds(playbackTime), format: .time(pattern: .minuteSecond))
          Spacer()
          Text(Duration.seconds(playbackDuration), format: .time(pattern: .minuteSecond))
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Slider(value: Binding(get: { playbackTime }, set: seek), in: 0...max(1, playbackDuration))
          .disabled(!canSeek || captureBusy).accessibilityLabel("Playback position")
          .accessibilityValue("\(Int(playbackTime)) seconds of \(Int(playbackDuration)) seconds")
          .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(playbackTime + 15)
            case .decrement: seek(playbackTime - 15)
            @unknown default: break
            }
          }
        HStack(spacing: 32) {
          Button("Back 15 seconds", systemImage: "gobackward.15") { seek(playbackTime - 15) }
            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .disabled(!canSeek)
          Button {
            Task {
              if let localAudio {
                await localAudio.playOrPause()
              } else {
                if let summary = currentSummary { hostAudio?.updateSummaryIfIdle(summary) }
                await hostAudio?.playOrPause()
              }
            }
          } label: {
            if dynamicTypeSize.isAccessibilitySize {
              Image(systemName: playbackSymbol)
                .font(.title.weight(.semibold))
                .frame(minWidth: 64, minHeight: 64)
                .padding(8)
            } else {
              Label(playbackLabel, systemImage: playbackSymbol)
                .font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
            }
          }
          .buttonStyle(.borderedProminent).tint(HarcMobilePalette.action)
          .foregroundStyle(HarcTideStyle.onAccent)
          .accessibilityLabel(playbackLabel)
          .accessibilityIdentifier("harc.mobile.detail.play")
          .disabled(audioIsLoading || (localAudio == nil && hostAudio == nil))
          Button("Forward 15 seconds", systemImage: "goforward.15") { seek(playbackTime + 15) }
            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .disabled(!canSeek)
        }.buttonStyle(.borderless).disabled(captureBusy)
        if audioIsLoading { ProgressView("Preparing audio…").font(.footnote) }
        if let audioFailure {
          VStack(alignment: .leading, spacing: 8) {
            Label("Audio couldn’t be played", systemImage: "exclamationmark.triangle")
              .font(.subheadline.weight(.medium))
            Text(
              localAudio != nil
                ? "The saved recording is still listed on this iPhone. Try again or export the audio."
                : "Your Mac’s receipt and processing status are separate from playback. Check that your Mac and its audio are available, then try again."
            )
            .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("Playback details") {
              Text(audioFailure).font(.footnote).textSelection(.enabled)
            }
          }
        } else if localAudio == nil && hostAudio == nil {
          Text("Audio is not available for playback yet. Its last reported status is shown above.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        if captureBusy {
          Text("Playback is paused while recording.").font(.caption).foregroundStyle(.secondary)
        }
      }.padding(.vertical, 8)
    }
  }
  private var playbackLabel: String {
    isPlaying ? "Pause" : (audioFailure == nil ? "Play" : "Try audio again")
  }
  private var playbackSymbol: String {
    isPlaying ? "pause.fill" : (audioFailure == nil ? "play.fill" : "arrow.clockwise")
  }
  private var playbackTime: TimeInterval { localAudio?.currentTime ?? hostAudio?.currentTime ?? 0 }
  private var playbackDuration: TimeInterval {
    let measured = localAudio?.duration ?? hostAudio?.duration ?? 0
    return measured > 0 ? measured : recordingDuration
  }
  private var envelope: [Float] { localAudio?.envelope ?? hostAudio?.envelope ?? [] }
  private var canSeek: Bool { localAudio?.canSeek ?? hostAudio?.canSeek ?? false }
  private var isPlaying: Bool { localAudio?.state == .playing || hostAudio?.state == .playing }
  private var audioIsLoading: Bool {
    localAudio?.state == .loading || hostAudio?.state == .downloading
  }
  private var audioFailure: String? {
    if case .failed(let message) = localAudio?.state { return message }
    if case .failed(let message) = hostAudio?.state { return message }
    return nil
  }
  private func seek(_ time: TimeInterval) {
    if let localAudio { localAudio.seek(to: time) } else { hostAudio?.seek(to: time) }
  }

  @ViewBuilder
  private func hostContent(
    _ detail: LibraryRecordingDetail, coordinator: HarcMobileLibraryCoordinator
  ) -> some View {
    if detail.captureNeedsReview {
      Section("Capture quality") {
        Label(
          "Some audio may be missing. Review this recording before relying on it.",
          systemImage: "exclamationmark.triangle"
        )
        .accessibilityIdentifier("harc.mobile.captureIntegrityWarning")
      }
    }
    if !detail.discontinuities.isEmpty {
      Section("Capture interruptions") {
        ForEach(
          Array(detail.discontinuities.enumerated()),
          id: \.offset
        ) { _, discontinuity in
          VStack(alignment: .leading, spacing: 4) {
            Label(
              Self.discontinuityText(
                discontinuity.reason
              ),
              systemImage:
                "waveform.badge.exclamationmark"
            )
            Text(
              discontinuity.wallTime,
              format: .dateTime
                .month().day().hour().minute()
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let routeChange = Self.routeChangeText(
              discontinuity
            ) {
              Text(routeChange)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    if selectedSection == .transcript {
      Section("Speakers") {
        if detail.speakerLabels.isEmpty {
          Text("No speaker labels are available yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(
            detail.speakerLabels,
            id: \.speakerIndex
          ) { label in
            HarcMobileSpeakerLabelEditor(
              label: label,
              displayName: speakerBinding(label, summary: detail.summary),
              profiles: coordinator.recognitionPack?.profiles ?? [],
              isSaving: isSavingMetadata,
              onSave: { displayName in
                submitMetadata(
                  .setSpeakerLabel(
                    index: label.speakerIndex,
                    displayName: displayName
                  ), expectedSummary: speakerDrafts[label.speakerIndex]?.baselineSummary
                )
              },
              onAssign: { personID in
                submitMetadata(
                  .assignSpeakerIdentity(
                    index: label.speakerIndex,
                    personID: personID
                  )
                )
              }
            )

          }
        }
        let missingDraftIndexes = speakerDrafts.keys.filter { index in
          !detail.speakerLabels.contains { $0.speakerIndex == index }
            && speakerDrafts[index]?.hasUnsavedChanges == true
        }.sorted()
        ForEach(missingDraftIndexes, id: \.self) { index in
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "Speaker \(index) is no longer listed on your Mac. Your unsaved name is kept here."
            )
            .font(.footnote).foregroundStyle(.secondary)
            TextField(
              "Speaker \(index) name",
              text: Binding(
                get: { speakerDrafts[index]?.text ?? "" },
                set: { speakerDrafts[index]?.text = $0 }
              ))
            Button("Save speaker name") {
              let name =
                speakerDrafts[index]?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              submitMetadata(
                .setSpeakerLabel(index: index, displayName: name.isEmpty ? nil : name),
                expectedSummary: speakerDrafts[index]?.baselineSummary)
            }.disabled(isSavingMetadata)
          }
        }
        TextField(
          "Speaker index",
          text: $newSpeakerIndex
        )
        .keyboardType(.numberPad)
        TextField(
          "Speaker display name",
          text: $newSpeakerName
        )
        Button("Add speaker label") {
          guard let index = UInt32(newSpeakerIndex) else {
            return
          }
          let displayName =
            newSpeakerName
            .trimmingCharacters(
              in: .whitespacesAndNewlines
            )
          submitMetadata(
            .setSpeakerLabel(
              index: index,
              displayName: displayName
            ), addingSpeaker: true
          )
        }
        .disabled(
          UInt32(newSpeakerIndex) == nil
            || newSpeakerName.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty
            || isSavingMetadata
        )
      }
    }
    if selectedSection == .notes {
      Section("Edit on Host") {
        TextField("Title", text: $titleDraft.text)
        Button("Save title") {
          let trimmed = titleDraft.text.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          submitMetadata(
            .setTitle(trimmed.isEmpty ? nil : titleDraft.text)
          )
        }
        TextField(
          "Tags separated by commas",
          text: $tagsDraft.text
        )
        Button("Replace tags") {
          submitMetadata(
            .replaceTags(
              tagsDraft.text.split(separator: ",").map {
                String($0)
              })
          )
        }
        TextEditor(text: $notesDraft.text)
          .frame(minHeight: 90)
          .accessibilityLabel("Notes")
        Button("Save notes") {
          let trimmed = notesDraft.text.trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          submitMetadata(
            .setNotesMarkdown(
              trimmed.isEmpty ? nil : notesDraft.text
            )
          )
        }
        Button(
          detail.summary.pinned
            ? "Unpin recording"
            : "Pin recording"
        ) {
          submitMetadata(
            .setPinned(!detail.summary.pinned)
          )
        }
        .disabled(isSavingMetadata)
      }
    }
    if isSavingMetadata || mutationMessage != nil {
      Section("Edit status") {
        if isSavingMetadata { ProgressView("Signing and sending…") }
        if let mutationMessage { Text(mutationMessage).font(.footnote).foregroundStyle(.secondary) }
      }
    }
    let visibleConflicts = coordinator.conflicts.filter {
      $0.canonicalRecordingID == detail.summary.canonicalID
    }
    if !visibleConflicts.isEmpty {
      Section("Edit conflicts") {
        ForEach(visibleConflicts, id: \.conflictID) { conflict in
          VStack(alignment: .leading, spacing: 6) {
            Text(
              "The Host advanced from revision \(conflict.expectedRevision.rawValue) to \(conflict.currentRevision.rawValue)."
            )
            .font(.footnote)
            Button("Use Mac value") { acceptHostConflict(conflict) }
              .disabled(isSavingMetadata)
          }
        }
      }
    }
    if selectedSection == .transcript, let transcript = detail.transcriptText,
      !transcript.isEmpty
    {
      Section("Transcript") {
        Text(
          SpeakerTranscriptLabelProjector.project(
            transcript,
            labels: detail.speakerLabels
          )
        )
        .textSelection(.enabled)
      }
    }
    if selectedSection == .summary, detail.summaryMarkdown?.isEmpty != false {
      pendingContent
    }
    if selectedSection == .transcript, detail.transcriptText?.isEmpty != false {
      pendingContent
    }
    if selectedSection == .summary, let generatedSummary = detail.summaryMarkdown,
      !generatedSummary.isEmpty
    {
      Section("Summary") {
        Text(generatedSummary)
          .textSelection(.enabled)
      }
    }
    if selectedSection == .summary, let actionItems = detail.actionItemsMarkdown,
      !actionItems.isEmpty
    {
      Section("Action Items") {
        Text(actionItems)
          .textSelection(.enabled)
      }
    }
    if selectedSection == .notes, let notes = detail.notesMarkdown, !notes.isEmpty {
      Section("Notes") {
        Text(notes)
          .textSelection(.enabled)
      }
    }

  }

  @ViewBuilder private var sectionPicker: some View {
    if dynamicTypeSize.isAccessibilitySize {
      Menu {
        ForEach(DetailSection.allCases, id: \.self) { section in
          Button(section.rawValue) { selectedSection = section }
        }
      } label: {
        Label(selectedSection.rawValue, systemImage: "chevron.up.chevron.down")
          .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
      }
      .accessibilityLabel("View \(selectedSection.rawValue)")
      .accessibilityIdentifier("harc.mobile.detail.sections")
    } else {
      Picker("Sections", selection: $selectedSection) {
        ForEach(DetailSection.allCases, id: \.self) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("harc.mobile.detail.sections")
    }
  }

  private func requestLeave(_ action: LeaveAction) {
    pendingLeave = action
    if hasUnsavedEdits { confirmsDiscard = true } else { performLeave() }
  }
  private func performLeave() {
    let action = pendingLeave
    pendingLeave = nil
    switch action {
    case .newRecording: newRecording()
    case .done: done?()
    case .back: dismiss()
    case .none: break
    }
  }
  private func speakerBinding(_ label: SpeakerLabel, summary: LibraryRecordingSummary) -> Binding<
    String
  > {
    Binding(
      get: { speakerDrafts[label.speakerIndex]?.text ?? label.displayName },
      set: { value in
        var draft = speakerDrafts[label.speakerIndex] ?? HarcMobileRecordingTextDraft()
        draft.receive(text: label.displayName, summary: summary)
        draft.text = value
        speakerDrafts[label.speakerIndex] = draft
      })
  }

  private func copyForPrompt() {
    guard let detail else { return }
    var parts = ["# \(detail.summary.title ?? detail.summary.suggestedTitle ?? "Recording")"]
    for (heading, text) in [
      ("Summary", detail.summaryMarkdown),
      ("Action items", detail.actionItemsMarkdown),
      ("Notes", detail.notesMarkdown),
    ] {
      if let text, !text.isEmpty { parts.append("## \(heading)\n\(text)") }
    }
    if let transcript = detail.transcriptText, !transcript.isEmpty {
      parts.append(
        "## Transcript\n"
          + SpeakerTranscriptLabelProjector.project(transcript, labels: detail.speakerLabels))
    }
    UIPasteboard.general.setItems(
      [["public.utf8-plain-text": parts.joined(separator: "\n\n")]],
      options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(300)])
    didCopyPrompt = true
  }

  private func acceptHostConflict(_ conflict: VisibleLibraryConflict) {
    guard let coordinator = model.libraryCoordinator, !isSavingMetadata else { return }
    let titleAtAcceptance = titleDraft.text
    let tagsAtAcceptance = tagsDraft.text
    let notesAtAcceptance = notesDraft.text
    let speakersAtAcceptance = speakerDrafts.mapValues(\.text)
    isSavingMetadata = true
    Task {
      defer { isSavingMetadata = false }
      do {
        let kind = try coordinator.mutationKind(for: conflict)
        let speakerIndex = try coordinator.conflictingSpeakerIndex(for: conflict)
        let fresh = try await coordinator.recordingDetail(
          canonicalID: conflict.canonicalRecordingID)
        try coordinator.acceptHostValue(for: conflict)
        switch kind {
        case .setTitle:
          titleDraft.acceptHostValue(
            submittedEditorText: titleAtAcceptance, summary: fresh.summary,
            serverText: fresh.summary.title ?? "")
        case .setTags:
          tagsDraft.acceptHostValue(
            submittedEditorText: tagsAtAcceptance, summary: fresh.summary,
            serverText: fresh.summary.tags.joined(separator: ", "))
        case .setNotes:
          notesDraft.acceptHostValue(
            submittedEditorText: notesAtAcceptance, summary: fresh.summary,
            serverText: fresh.notesMarkdown ?? "")
        case .setSpeakerLabel:
          if let index = speakerIndex, let submitted = speakersAtAcceptance[index] {
            speakerDrafts[index]?.acceptHostValue(
              submittedEditorText: submitted, summary: fresh.summary,
              serverText: fresh.speakerLabels.first { $0.speakerIndex == index }?.displayName ?? "")
          }
        default: break
        }
        mutationMessage =
          "Conflicting edit dismissed using your Mac’s value. Any newer typing is kept."
        await loadDetail()
      } catch {
        mutationMessage = "Couldn’t resolve this edit with your Mac. Your text is unchanged."
      }
    }
  }

  private func submitMetadata(
    _ mutation: HarcMobileMetadataMutation, expectedSummary: LibraryRecordingSummary? = nil,
    addingSpeaker: Bool = false
  ) {
    guard let coordinator = model.libraryCoordinator,
      let current = detail?.summary,
      !isSavingMetadata
    else { return }
    let alreadyQueued: Bool
    switch mutation {
    case .setTitle: alreadyQueued = titleDraft.hasQueuedSubmission
    case .replaceTags: alreadyQueued = tagsDraft.hasQueuedSubmission
    case .setNotesMarkdown: alreadyQueued = notesDraft.hasQueuedSubmission
    case .setSpeakerLabel(let index, _):
      alreadyQueued = speakerDrafts[index]?.hasQueuedSubmission == true
    default: alreadyQueued = false
    }
    guard !alreadyQueued else {
      mutationMessage =
        "Your previous edit is waiting for your Mac. Your newer typing is kept here; save it after that edit syncs or its conflict is resolved."
      return
    }
    let baseline: LibraryRecordingSummary
    let submittedText: String?
    switch mutation {
    case .setTitle:
      baseline = titleDraft.baselineSummary ?? current
      submittedText = titleDraft.text
    case .replaceTags:
      baseline = tagsDraft.baselineSummary ?? current
      submittedText = tagsDraft.text
    case .setNotesMarkdown:
      baseline = notesDraft.baselineSummary ?? current
      submittedText = notesDraft.text
    case .setSpeakerLabel(let index, _):
      baseline = expectedSummary ?? current
      submittedText = speakerDrafts[index]?.text
    default:
      baseline = expectedSummary ?? current
      submittedText = nil
    }
    let expectedServerText: String?
    switch mutation {
    case .setTitle(let value), .setNotesMarkdown(let value): expectedServerText = value ?? ""
    case .replaceTags(let values):
      expectedServerText = Array(
        Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
          .filter { !$0.isEmpty }
      ).sorted().joined(separator: ", ")
    case .setSpeakerLabel(_, let value): expectedServerText = value ?? ""
    default: expectedServerText = nil
    }
    let submittedSpeakerIndex = newSpeakerIndex
    let submittedSpeakerName = newSpeakerName
    isSavingMetadata = true
    mutationMessage = nil
    Task {
      defer { isSavingMetadata = false }
      do {
        let submission = try await coordinator.submitMetadataMutation(
          summary: baseline,
          mutation: mutation
        )
        let outcome = submission.outcome
        if addingSpeaker, outcome == .applied || outcome == .queuedOffline,
          newSpeakerIndex == submittedSpeakerIndex, newSpeakerName == submittedSpeakerName
        {
          newSpeakerIndex = ""
          newSpeakerName = ""
        }
        switch outcome {
        case .applied:
          mutationMessage = "Saved on your Mac."
          if let submittedText,
            let saved = try? await coordinator.recordingDetail(canonicalID: baseline.canonicalID)
          {
            switch mutation {
            case .setTitle:
              titleDraft.acceptSaved(
                submitted: submittedText, summary: saved.summary,
                serverText: saved.summary.title ?? "", expectedServerText: expectedServerText)
            case .replaceTags:
              tagsDraft.acceptSaved(
                submitted: submittedText, summary: saved.summary,
                serverText: saved.summary.tags.joined(separator: ", "),
                expectedServerText: expectedServerText)
            case .setNotesMarkdown:
              notesDraft.acceptSaved(
                submitted: submittedText, summary: saved.summary,
                serverText: saved.notesMarkdown ?? "", expectedServerText: expectedServerText)
            case .setSpeakerLabel(let index, _):
              speakerDrafts[index]?.acceptSaved(
                submitted: submittedText, summary: saved.summary,
                serverText: saved.speakerLabels.first { $0.speakerIndex == index }?.displayName
                  ?? "", expectedServerText: expectedServerText)
            default: break
            }
          }
          await loadDetail()
        case .queuedOffline:
          if let submittedText {
            switch mutation {
            case .setTitle(let value):
              titleDraft.markQueued(
                submitted: submittedText, expectedServerText: value ?? "",
                operationID: submission.operationID)
            case .replaceTags(let values):
              let normalized = Array(
                Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                  .filter { !$0.isEmpty }
              ).sorted().joined(separator: ", ")
              tagsDraft.markQueued(
                submitted: submittedText, expectedServerText: normalized,
                operationID: submission.operationID)
            case .setNotesMarkdown(let value):
              notesDraft.markQueued(
                submitted: submittedText, expectedServerText: value ?? "",
                operationID: submission.operationID)
            case .setSpeakerLabel(let index, let value):
              speakerDrafts[index]?.markQueued(
                submitted: submittedText, expectedServerText: value ?? "",
                operationID: submission.operationID)
            default: break
            }
          }
          mutationMessage =
            "Saved safely on this iPhone; it will retry when the Host is online."
        case .conflict:
          mutationMessage =
            "The Host has a newer revision. Review the conflict below."
        }
      } catch {
        mutationMessage = HarcTransportErrorDiagnostic.describe(error).userFacingMessage
      }
    }
  }

  private func loadDetail() async {
    detailRequestGeneration += 1
    let generation = detailRequestGeneration
    model.transferCoordinator?.refreshLocalRecordings()
    model.libraryCoordinator?.refresh()
    guard let coordinator = model.libraryCoordinator, let summary = resolved.host else { return }
    do {
      let loaded = try await coordinator.recordingDetail(canonicalID: summary.canonicalID)
      guard !Task.isCancelled, generation == detailRequestGeneration,
        loaded.summary.canonicalID == summary.canonicalID,
        loaded.summary.originID == summary.originID
      else { return }
      if let previous = detail,
        loaded.summary.revision.rawValue < previous.summary.revision.rawValue
      {
        return
      }
      let pending = try? coordinator.pendingMetadataOperationIDs()
      titleDraft.receive(
        text: loaded.summary.title ?? "", summary: loaded.summary, pendingOperations: pending)
      tagsDraft.receive(
        text: loaded.summary.tags.joined(separator: ", "), summary: loaded.summary,
        pendingOperations: pending)
      notesDraft.receive(
        text: loaded.notesMarkdown ?? "", summary: loaded.summary, pendingOperations: pending)
      for label in loaded.speakerLabels {
        var draft = speakerDrafts[label.speakerIndex] ?? HarcMobileRecordingTextDraft()
        draft.receive(text: label.displayName, summary: loaded.summary, pendingOperations: pending)
        speakerDrafts[label.speakerIndex] = draft
      }
      let presentSpeakerIndexes = Set(loaded.speakerLabels.map(\.speakerIndex))
      for index in Array(speakerDrafts.keys) where !presentSpeakerIndexes.contains(index) {
        speakerDrafts[index]?.receive(text: "", summary: loaded.summary, pendingOperations: pending)
      }
      // A later Mac edit can overtake our acknowledged value before this GET.
      // Only exact durable operation completion clears a pending marker; retain
      // the original baseline so any newer local edit takes the conflict path.
      if let pending {
        titleDraft.reconcilePendingOperations(pending)
        tagsDraft.reconcilePendingOperations(pending)
        notesDraft.reconcilePendingOperations(pending)
        for index in Array(speakerDrafts.keys) {
          speakerDrafts[index]?.reconcilePendingOperations(pending)
        }
      }
      if UIAccessibility.isVoiceOverRunning {
        if !announcedSummary, loaded.summaryMarkdown?.isEmpty == false {
          UIAccessibility.post(notification: .announcement, argument: "Summary ready")
          announcedSummary = true
          announcedTranscript = loaded.transcriptText?.isEmpty == false
        } else if !announcedTranscript, loaded.transcriptText?.isEmpty == false {
          UIAccessibility.post(notification: .announcement, argument: "Transcript ready")
          announcedTranscript = true
        }
      }
      detail = loaded
      hostAudio?.updateSummaryIfIdle(loaded.summary)
      errorMessage = nil
      preparePlayback()
    } catch {
      guard !Task.isCancelled, generation == detailRequestGeneration else { return }
      errorMessage = "Couldn’t refresh recording text from your Mac. Your saved audio is unchanged."
    }
  }

  private static func discontinuityText(
    _ reason: CaptureDiscontinuityReason
  ) -> String {
    switch reason {
    case .interruptionBegan: "Audio interruption began"
    case .interruptionEnded: "Audio interruption ended"
    case .routeChanged: "Microphone route changed"
    case .engineConfigurationChanged: "Audio configuration changed"
    case .mediaServicesLost: "iOS audio services were lost"
    case .mediaServicesReset: "iOS audio services reset"
    case .writerFailure: "Local audio writer failed"
    case .bufferOverrun: "Audio buffer overrun"
    case .recovery: "Durable recording recovery"
    }
  }

  private static func routeChangeText(
    _ discontinuity: CaptureDiscontinuity
  ) -> String? {
    let oldName =
      discontinuity.oldRoute?.name
      ?? discontinuity.oldRoute?.identifier
    let newName =
      discontinuity.newRoute?.name
      ?? discontinuity.newRoute?.identifier
    return switch (oldName, newName) {
    case (.some(let old), .some(let new)):
      "\(old) → \(new)"
    case (.some(let old), .none):
      "Previous route: \(old)"
    case (.none, .some(let new)):
      "New route: \(new)"
    case (.none, .none):
      nil
    }
  }

}
