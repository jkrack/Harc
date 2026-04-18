import Foundation

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
                    if try await store.fetchByWavPath(wav.path) != nil { continue }

                    let stem = wav.deletingPathExtension().lastPathComponent
                    let parent = wav.deletingLastPathComponent()
                    let txt = parent.appendingPathComponent("\(stem).txt")
                    let json = parent.appendingPathComponent("\(stem).json")

                    let txtExists = fm.fileExists(atPath: txt.path)
                    let jsonExists = fm.fileExists(atPath: json.path)

                    let transcriptText: String? = txtExists
                        ? (try? String(contentsOf: txt, encoding: .utf8))
                        : nil

                    let startedAt = parseStartedAt(
                        day: dayDir.lastPathComponent,
                        time: stem
                    ) ?? fileCreated(url: wav)

                    let recording = Recording(
                        wavPath: wav.path,
                        txtPath: txtExists ? txt.path : nil,
                        jsonPath: jsonExists ? json.path : nil,
                        startedAt: startedAt,
                        transcriptText: transcriptText
                    )
                    _ = try await store.upsert(recording)
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
