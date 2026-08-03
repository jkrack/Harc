import Foundation
import HarcCore

/// Scans a destination folder and upserts any WAVs not already in the store.
/// Designed to run once on app startup; cheap for modest library sizes.
public struct RecordingIngestor: Sendable {
    public let baseDirectory: URL
    public let store: RecordingStore

    public init(baseDirectory: URL, store: RecordingStore) {
        self.baseDirectory = baseDirectory
        self.store = store
    }

    /// Walks the YYYY/YYYY-MM-DD/*.wav hierarchy. For each WAV not yet in the
    /// store, inserts a row with text from its `.txt` sibling (if present).
    /// Returns the number of new rows inserted.
    @discardableResult
    public func ingestAll() async throws -> Int {
        let fm = FileManager.default
        guard let yearDirs = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var inserted = 0
        for yearDir in yearDirs where isDirectory(yearDir) {
            guard let dayDirs = try? fm.contentsOfDirectory(
                at: yearDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for dayDir in dayDirs where isDirectory(dayDir) {
                guard let files = try? fm.contentsOfDirectory(
                    at: dayDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }

                for wav in files where wav.pathExtension.lowercased() == "wav" {
                    let stem = wav.deletingPathExtension().lastPathComponent
                    // UUID stems are reserved for Host canonical publication.
                    // A crash can leave the exclusively renamed WAV visible
                    // before its Harc.db row is committed; legacy startup
                    // ingest must never adopt that file with a random local
                    // canonical identity and block journal recovery.
                    if UUID(uuidString: stem) != nil { continue }
                    if try await store.fetchByWavPath(wav.path) != nil { continue }

                    let parent = wav.deletingLastPathComponent()
                    let md = parent.appendingPathComponent("\(stem).md")
                    let txt = parent.appendingPathComponent("\(stem).txt")
                    let json = parent.appendingPathComponent("\(stem).json")

                    let mdExists = fm.fileExists(atPath: md.path)
                    let txtExists = fm.fileExists(atPath: txt.path)
                    let jsonExists = fm.fileExists(atPath: json.path)

                    // Canonical artifact is the OKF .md (transcript section
                    // only — summary text would pollute FTS search); .txt is
                    // the pre-OKF legacy fallback.
                    let transcriptText: String?
                    if mdExists, let content = try? String(contentsOf: md, encoding: .utf8) {
                        transcriptText = OKFMarkdown.extractTranscript(from: content) ?? content
                    } else if txtExists {
                        transcriptText = try? String(contentsOf: txt, encoding: .utf8)
                    } else {
                        transcriptText = nil
                    }

                    let startedAt = parseStartedAt(
                        day: dayDir.lastPathComponent,
                        time: stem
                    ) ?? fileCreated(url: wav)

                    let recording = Recording(
                        wavPath: wav.path,
                        txtPath: mdExists ? md.path : (txtExists ? txt.path : nil),
                        jsonPath: jsonExists ? json.path : nil,
                        startedAt: startedAt,
                        transcriptText: transcriptText
                    )
                    let persisted = try await store.upsert(recording)
                    if let transcriptText, let id = persisted.id {
                        Task.detached { [store] in
                            let entities = TitleSuggester.extractEntities(from: transcriptText)
                            if entities.isEmpty { return }
                            let suggestion = Array(entities.prefix(2)).joined(separator: ", ")
                            try? await store.updateSuggestedTitle(id: id, title: suggestion)
                            try? await store.updateTags(id: id, tags: entities)
                        }
                    }
                    inserted += 1
                }
            }
        }
        return inserted
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// "2026-04-17" + "10-00-00" → Date, in local time zone.
    private func parseStartedAt(day: String, time: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH-mm-ss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: "\(day) \(time)")
    }

    private func fileCreated(url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? Date()
    }
}
