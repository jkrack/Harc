import Foundation
import HarcClient
import HarcCore
import HarcStore

/// Immutable snapshot of a recording's text + metadata for the editor.
/// Loading is tolerant of partial data: text may come from .txt or fall back
/// to SessionTranscript.joinedText; missing .wav is indicated via flag.
public struct TranscriptDocument: Sendable {
    public let recordingID: Int64?
    public let initialText: String
    public let words: [Word]
    public let speakers: [SpeakerSegment]
    public let wavURL: URL?
    public let txtURL: URL
    public let jsonURL: URL?
    public let wordIndex: WordIndex
    public let audioAvailable: Bool
    public let jsonAvailable: Bool

    public init(
        recordingID: Int64?,
        initialText: String,
        words: [Word],
        speakers: [SpeakerSegment],
        wavURL: URL?,
        txtURL: URL,
        jsonURL: URL?,
        audioAvailable: Bool,
        jsonAvailable: Bool
    ) {
        self.recordingID = recordingID
        self.initialText = initialText
        self.words = words
        self.speakers = speakers
        self.wavURL = wavURL
        self.txtURL = txtURL
        self.jsonURL = jsonURL
        self.audioAvailable = audioAvailable
        self.jsonAvailable = jsonAvailable
        self.wordIndex = WordIndex(words: words, text: initialText)
    }

    public static func load(recording: Recording) -> TranscriptDocument {
        let fm = FileManager.default
        let wavURL = URL(fileURLWithPath: recording.wavPath)
        let audioAvailable = fm.fileExists(atPath: wavURL.path)

        // Canonical text artifact is the OKF `.md` next to the WAV; a `.txt`
        // txtPath is a pre-OKF legacy row and is still honored for reads.
        let mdURL = wavURL.deletingPathExtension().appendingPathExtension("md")
        let txtURL: URL
        if fm.fileExists(atPath: mdURL.path) {
            txtURL = mdURL
        } else if let path = recording.txtPath {
            txtURL = URL(fileURLWithPath: path)
        } else {
            txtURL = mdURL
        }

        let jsonURL = recording.jsonPath.map { URL(fileURLWithPath: $0) }
        let jsonAvailable = jsonURL.map { fm.fileExists(atPath: $0.path) } ?? false

        var words: [Word] = []
        var speakers: [SpeakerSegment] = []
        var jsonJoinedText: String?
        var structuredTranscript: SessionTranscript?

        if let jsonURL, jsonAvailable,
           let data = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let transcript = try? decoder.decode(SessionTranscript.self, from: data) {
                structuredTranscript = transcript
                words = transcript.words
                speakers = transcript.speakers
                jsonJoinedText = transcript.joinedText
            }
        }

        let artifactText: String
        if let data = try? Data(contentsOf: txtURL),
           let s = String(data: data, encoding: .utf8) {
            // OKF documents carry frontmatter + summary; the editor operates
            // on the transcript section only.
            artifactText = OKFMarkdown.extractTranscript(from: s) ?? s
        } else if let joined = jsonJoinedText {
            artifactText = joined
        } else if let stored = recording.transcriptText {
            artifactText = stored
        } else {
            artifactText = ""
        }

        // Older Client-local rows stored joinedText in the DB, so a later
        // metadata projection could replace an initially diarized Markdown
        // transcript with one flat paragraph. Recover the generated turn
        // labels from the still-structured sidecar. Never do this after a
        // manual edit: its words/timing no longer safely describe the text.
        let text: String
        if let transcript = structuredTranscript,
           transcript.manualEditAt == nil,
           !transcript.words.isEmpty,
           !transcript.speakers.isEmpty,
           !Self.containsSpeakerTurn(in: artifactText, recording: recording) {
            text = TranscriptPlainTextRenderer.render(transcript)
        } else {
            text = artifactText
        }

        return TranscriptDocument(
            recordingID: recording.id,
            initialText: text,
            words: words,
            speakers: speakers,
            wavURL: audioAvailable ? wavURL : nil,
            txtURL: txtURL,
            jsonURL: jsonURL,
            audioAvailable: audioAvailable,
            jsonAvailable: jsonAvailable
        )
    }

    private static func containsSpeakerTurn(
        in text: String,
        recording: Recording
    ) -> Bool {
        var labels = Set(recording.speakerNames.values)
        labels.formUnion((1...12).map { "Speaker \($0)" })
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .contains { line in
                guard let colon = line.firstIndex(of: ":") else { return false }
                let head = line[..<colon].trimmingCharacters(in: .whitespaces)
                return labels.contains(head)
            }
    }

    /// Return the same document metadata with a different presentation text
    /// and a word index rebuilt for that text. Speaker identity changes the
    /// visible turn headers, so offsets must be refreshed at the same time.
    public func replacingInitialText(_ text: String) -> TranscriptDocument {
        TranscriptDocument(
            recordingID: recordingID,
            initialText: text,
            words: words,
            speakers: speakers,
            wavURL: wavURL,
            txtURL: txtURL,
            jsonURL: jsonURL,
            audioAvailable: audioAvailable,
            jsonAvailable: jsonAvailable
        )
    }

    /// Atomic write of the edited text to `txtURL`, plus a best-effort stamp
    /// of `manualEditAt` onto the JSON. JSON-stamp failures are logged to
    /// stderr but don't fail the save.
    ///
    /// When the target is an OKF `.md`, only the transcript section is
    /// replaced — frontmatter and summary on disk are preserved. (The store
    /// also reprojects the whole file from the DB after
    /// `updateTranscriptText`, so this is belt-and-braces for the window
    /// between file write and DB commit.)
    public func save(editedText: String) throws -> URL {
        let payload: String
        if txtURL.pathExtension.lowercased() == "md" {
            if let existing = try? String(contentsOf: txtURL, encoding: .utf8),
               let replaced = OKFMarkdown.replacingTranscript(in: existing, with: editedText) {
                payload = replaced
            } else {
                payload = OKFMarkdown.render(OKFMarkdown.Fields(
                    title: txtURL.deletingPathExtension().lastPathComponent,
                    transcript: editedText
                ))
            }
        } else {
            payload = editedText
        }
        let data = Data(payload.utf8)
        let tmp = txtURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: txtURL.path) {
                _ = try FileManager.default.replaceItemAt(txtURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: txtURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        stampManualEditAtOnJSON()
        return txtURL
    }

    private func stampManualEditAtOnJSON() {
        guard let jsonURL, jsonAvailable,
              let data = try? Data(contentsOf: jsonURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var transcript = try? decoder.decode(SessionTranscript.self, from: data) else {
            FileHandle.standardError.write(Data(
                "harc-editor: couldn't decode JSON to stamp manualEditAt: \(jsonURL.path)\n".utf8
            ))
            return
        }
        transcript.manualEditAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let out = try? encoder.encode(transcript) else {
            FileHandle.standardError.write(Data(
                "harc-editor: couldn't re-encode JSON to stamp manualEditAt: \(jsonURL.path)\n".utf8
            ))
            return
        }
        do {
            try out.write(to: jsonURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "harc-editor: couldn't write stamped JSON: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}
