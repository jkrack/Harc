import Foundation
import Combine

/// A row in the recordings list. `wavURL` is the canonical key; `txtURL`/`jsonURL`
/// may be nil for recordings where transcription failed or is still in flight.
public struct RecordingEntry: Identifiable, Hashable, Sendable {
    public let id: URL        // wavURL
    public let wavURL: URL
    public let txtURL: URL?
    public let jsonURL: URL?
    public let date: String   // "2026-04-17 09:30:15"
    public let preview: String?  // first ~120 chars of the .txt, if present
}

/// Scans the destination folder on demand for `.wav` recordings + siblings.
/// Plan 6 will replace this with a GRDB-backed index + FTS search.
@MainActor
public final class RecordingsIndex: ObservableObject {
    @Published public private(set) var entries: [RecordingEntry] = []

    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public func refresh() {
        let fm = FileManager.default
        var found: [RecordingEntry] = []

        guard let yearDirs = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            entries = []
            return
        }

        for yearDir in yearDirs where isDirectory(yearDir) {
            guard let dayDirs = try? fm.contentsOfDirectory(
                at: yearDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for dayDir in dayDirs where isDirectory(dayDir) {
                guard let files = try? fm.contentsOfDirectory(
                    at: dayDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for wav in files where wav.pathExtension.lowercased() == "wav" {
                    let stem = wav.deletingPathExtension().lastPathComponent
                    let parent = wav.deletingLastPathComponent()
                    let txt = parent.appendingPathComponent("\(stem).txt")
                    let json = parent.appendingPathComponent("\(stem).json")

                    let txtExists = fm.fileExists(atPath: txt.path)
                    let jsonExists = fm.fileExists(atPath: json.path)

                    let day = dayDir.lastPathComponent
                    let dateString = "\(day) \(stem.replacingOccurrences(of: "-", with: ":"))"

                    let preview: String?
                    if txtExists, let text = try? String(contentsOf: txt, encoding: .utf8) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        preview = String(trimmed.prefix(120))
                    } else {
                        preview = nil
                    }

                    found.append(RecordingEntry(
                        id: wav,
                        wavURL: wav,
                        txtURL: txtExists ? txt : nil,
                        jsonURL: jsonExists ? json : nil,
                        date: dateString,
                        preview: preview
                    ))
                }
            }
        }

        // Newest first by date string (YYYY-MM-DD HH:MM:SS sorts lexicographically).
        found.sort { $0.date > $1.date }
        entries = found
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
