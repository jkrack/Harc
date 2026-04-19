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

        let txtURL: URL
        if let path = recording.txtPath {
            txtURL = URL(fileURLWithPath: path)
        } else {
            txtURL = wavURL.deletingPathExtension().appendingPathExtension("txt")
        }

        let jsonURL = recording.jsonPath.map { URL(fileURLWithPath: $0) }
        let jsonAvailable = jsonURL.map { fm.fileExists(atPath: $0.path) } ?? false

        var words: [Word] = []
        var speakers: [SpeakerSegment] = []
        var jsonJoinedText: String?

        if let jsonURL, jsonAvailable,
           let data = try? Data(contentsOf: jsonURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let transcript = try? decoder.decode(SessionTranscript.self, from: data) {
                words = transcript.words
                speakers = transcript.speakers
                jsonJoinedText = transcript.joinedText
            }
        }

        let text: String
        if let data = try? Data(contentsOf: txtURL),
           let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let joined = jsonJoinedText {
            text = joined
        } else if let stored = recording.transcriptText {
            text = stored
        } else {
            text = ""
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

    /// Atomic write of the edited text to `txtURL`, plus a best-effort stamp
    /// of `manualEditAt` onto the JSON. JSON-stamp failures are logged to
    /// stderr but don't fail the save.
    public func save(editedText: String) throws -> URL {
        let data = Data(editedText.utf8)
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
