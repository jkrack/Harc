import Foundation
import Combine
import HarcClient
import HarcCore
import HarcStore

@MainActor
public final class TranscriptEditorViewModel: ObservableObject {
    public let recording: Recording
    public let document: TranscriptDocument

    @Published public var editedText: String
    @Published public private(set) var isDirty: Bool = false
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTimeSec: Double = 0
    @Published public private(set) var durationSec: Double = 0
    @Published public private(set) var currentHighlightRange: NSRange? = nil
    @Published public private(set) var audioMissing: Bool
    @Published public private(set) var wordIndexStale: Bool = false
    @Published public private(set) var saveError: String? = nil

    private let player: TranscriptAudioPlayer
    private let store: RecordingStore
    private var pollTask: Task<Void, Never>?

    /// Initializer. Non-throwing by design — missing / unreadable audio
    /// surfaces as `audioMissing = true` rather than a failed init.
    public init(
        recording: Recording,
        store: RecordingStore,
        player: TranscriptAudioPlayer = .init()
    ) async {
        self.recording = recording
        self.store = store
        self.player = player
        let doc = TranscriptDocument.load(recording: recording)
        self.document = doc
        self.editedText = doc.initialText

        var audioMissingInit = !doc.audioAvailable
        if let wavURL = doc.wavURL {
            do {
                try await player.load(url: wavURL)
                self.durationSec = await player.duration
            } catch {
                audioMissingInit = true
            }
        }
        self.audioMissing = audioMissingInit
    }

    public func togglePlay() {
        guard !audioMissing else { return }
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    public func seek(to seconds: Double) {
        Task { [player] in
            await player.seek(to: seconds)
            let t = await player.currentTime
            self.currentTimeSec = t
        }
    }

    public func skip(by seconds: Double) {
        seek(to: currentTimeSec + seconds)
    }

    /// Look up the word containing `charOffset` and seek audio to its start.
    public func seekToWord(atCharOffset offset: Int) {
        guard !audioMissing else { return }
        guard let entry = document.wordIndex.wordAt(charOffset: offset) else { return }
        seek(to: Double(entry.word.startMs) / 1000.0)
    }

    public func markEdited(newText: String) {
        guard newText != editedText else { return }
        editedText = newText
        isDirty = true
        wordIndexStale = true
        currentHighlightRange = nil
    }

    public func save() async {
        do {
            _ = try document.save(editedText: editedText)
            if let id = recording.id {
                try await store.updateTranscriptText(id: id, text: editedText)
            }
            isDirty = false
            saveError = nil
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// Persist a new custom title for this recording. Pass nil/empty to clear.
    /// Mirrors `LibraryViewModel.rename` so the editor can rename in place.
    public func renameTitle(_ raw: String?) async {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard let id = recording.id else { return }
        do {
            try await store.rename(id: id, title: value)
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    public func clearSaveError() {
        saveError = nil
    }

    public func stopPlayback() {
        pollTask?.cancel()
        pollTask = nil
        Task { [player] in await player.pause() }
        isPlaying = false
    }

    private func startPlayback() {
        Task { [player] in await player.play() }
        isPlaying = true
        pollTask?.cancel()
        pollTask = Task { [weak self, player] in
            while !Task.isCancelled {
                let t = await player.currentTime
                let playing = await player.isPlaying
                await MainActor.run {
                    guard let self else { return }
                    self.currentTimeSec = t
                    if !self.wordIndexStale {
                        self.currentHighlightRange = self.document.wordIndex
                            .wordAt(timeMs: Int(t * 1000))?.range
                    }
                    if !playing && self.isPlaying {
                        // Audio reached end; reflect stopped state.
                        self.isPlaying = false
                    }
                }
                if !playing { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }
}
