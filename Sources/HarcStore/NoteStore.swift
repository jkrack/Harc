import Foundation
import Security

public actor NoteStore {
    public let rootURL: URL

    public init(rootURL: URL = NoteStore.defaultURL()) {
        self.rootURL = rootURL
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc/Notes", isDirectory: true)
    }

    public func fetchAll(includeArchived: Bool = false) async throws -> [Note] {
        try ensureRoot()
        let urls = try markdownFileURLs()
        let notes = try urls
            .map { try Self.loadNote(from: $0, rootURL: rootURL) }
            .filter { includeArchived || !$0.archived }
        return notes.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func create(
        title rawTitle: String? = nil,
        body: String = "",
        recordings: [String] = []
    ) async throws -> Note {
        try ensureRoot()
        let now = Date()
        let id = Self.makeULID()
        let title = cleanedTitle(rawTitle) ?? Self.defaultTitle(createdAt: now)
        let folderPath = Self.folderPath(for: now)
        let url = rootURL
            .appendingPathComponent(folderPath, isDirectory: true)
            .appendingPathComponent("\(id).md")
        let note = Note(
            id: id,
            title: title,
            body: body,
            recordings: recordings,
            folderPath: folderPath,
            createdAt: now,
            updatedAt: now,
            fileURL: url
        )
        try Self.write(note)
        return note
    }

    public func create(for recording: Recording, body: String = "") async throws -> Note {
        try await create(
            title: recording.displayTitle,
            body: body,
            recordings: [Self.recordingLinkID(for: recording)]
        )
    }

    public func link(
        recording: Recording,
        toNoteID noteID: String,
        transcriptText: String? = nil
    ) async throws -> Note {
        guard var note = try await fetchAll(includeArchived: true).first(where: { $0.id == noteID }) else {
            throw StoreError.notFound
        }
        let linkID = Self.recordingLinkID(for: recording)
        if !note.recordings.contains(linkID) {
            note.recordings.append(linkID)
        }
        if let transcriptText = transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcriptText.isEmpty {
            note.body = Self.appendingRecordingTranscript(
                to: note.body,
                recording: recording,
                transcriptText: transcriptText
            )
        }
        return try await update(note)
    }

    public func fetchLinked(to recording: Recording) async throws -> [Note] {
        let linkID = Self.recordingLinkID(for: recording)
        return try await fetchAll(includeArchived: false)
            .filter { $0.recordings.contains(linkID) }
    }

    public func search(query: String) async throws -> [Note] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        return try await fetchAll(includeArchived: false).filter { note in
            let haystack = (
                [note.title, note.body, note.folderPath ?? ""] +
                note.tags +
                note.people
            )
            .joined(separator: " ")
            .lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    public func update(_ note: Note) async throws -> Note {
        try ensureRoot()
        var next = note
        next.title = cleanedTitle(note.title) ?? Self.defaultTitle(createdAt: note.createdAt)
        next.updatedAt = Date()
        try Self.write(next)
        return next
    }

    public func archive(id: String) async throws {
        guard var note = try await fetchAll(includeArchived: true).first(where: { $0.id == id }) else {
            throw StoreError.notFound
        }
        note.archived = true
        _ = try await update(note)
    }

    public func setPinned(id: String, pinned: Bool) async throws {
        guard var note = try await fetchAll(includeArchived: true).first(where: { $0.id == id }) else {
            throw StoreError.notFound
        }
        note.pinned = pinned
        _ = try await update(note)
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func markdownFileURLs() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "md" else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }

    private func cleanedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public extension NoteStore {
    static func recordingLinkID(for recording: Recording) -> String {
        if let id = recording.id {
            return "recording:\(id)"
        }
        return "recording-path:\(recording.wavPath)"
    }
}

private extension NoteStore {
    static func loadNote(from url: URL, rootURL: URL) throws -> Note {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let parsed = parseDocument(raw)
        let id = parsed.scalar["id"] ?? url.deletingPathExtension().lastPathComponent
        let now = Date()
        let inferredFolderPath = inferFolderPath(for: url, rootURL: rootURL)
        return Note(
            id: id,
            title: parsed.scalar["title"] ?? "Untitled",
            body: parsed.body,
            tags: parsed.list["tags"] ?? [],
            recordings: parsed.list["recordings"] ?? [],
            people: parsed.list["people"] ?? [],
            derivedFrom: emptyToNil(parsed.scalar["derived_from"]),
            folderPath: emptyToNil(parsed.scalar["folder_path"]) ?? inferredFolderPath,
            pinned: Bool(parsed.scalar["pinned"] ?? "false") ?? false,
            archived: Bool(parsed.scalar["archived"] ?? "false") ?? false,
            createdAt: parseDate(parsed.scalar["created_at"]) ?? now,
            updatedAt: parseDate(parsed.scalar["updated_at"]) ?? now,
            fileURL: url
        )
    }

    static func write(_ note: Note) throws {
        let text = render(note)
        try FileManager.default.createDirectory(
            at: note.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: note.fileURL, atomically: true, encoding: .utf8)
    }

    static func folderPath(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        return String(format: "%04d/%02d/%02d", year, month, day)
    }

    static func defaultTitle(createdAt date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func inferFolderPath(for url: URL, rootURL: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let root = rootURL.standardizedFileURL.path
        guard parent != root, parent.hasPrefix(root + "/") else { return nil }
        return String(parent.dropFirst(root.count + 1))
    }

    static func parseDocument(_ raw: String) -> (scalar: [String: String], list: [String: [String]], body: String) {
        guard raw.hasPrefix("---\n") || raw == "---" else {
            return ([:], [:], raw)
        }
        let lines = raw.components(separatedBy: .newlines)
        var scalar: [String: String] = [:]
        var list: [String: [String]] = [:]
        var currentListKey: String?
        var bodyStart: Int?

        for index in 1..<lines.count {
            let line = lines[index]
            if line == "---" {
                bodyStart = index + 1
                break
            }
            if line.hasPrefix("  - "), let key = currentListKey {
                list[key, default: []].append(String(line.dropFirst(4)))
                continue
            }
            currentListKey = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                currentListKey = key
                list[key] = []
            } else {
                scalar[key] = value
            }
        }

        let body: String
        if let bodyStart, bodyStart < lines.count {
            body = lines[bodyStart...].joined(separator: "\n")
        } else {
            body = ""
        }
        return (scalar, list, body)
    }

    static func render(_ note: Note) -> String {
        var lines: [String] = [
            "---",
            "id: \(note.id)",
            "title: \(oneLine(note.title))",
            "created_at: \(formatDate(note.createdAt))",
            "updated_at: \(formatDate(note.updatedAt))",
            "pinned: \(note.pinned)",
            "archived: \(note.archived)",
            "folder_path: \(note.folderPath ?? "")",
            "derived_from: \(note.derivedFrom ?? "")",
        ]
        appendList("tags", note.tags, to: &lines)
        appendList("recordings", note.recordings, to: &lines)
        appendList("people", note.people, to: &lines)
        lines.append("---")
        lines.append(note.body)
        return lines.joined(separator: "\n")
    }

    static func appendList(_ key: String, _ values: [String], to lines: inout [String]) {
        lines.append("\(key):")
        for value in values {
            lines.append("  - \(oneLine(value))")
        }
    }

    static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
    }

    static func appendingRecordingTranscript(
        to body: String,
        recording: Recording,
        transcriptText: String
    ) -> String {
        let title = recording.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkTitle = title.isEmpty ? "Recording" : title
        let block = """
        ## Recording: [[\(linkTitle)]]

        \(transcriptText)
        """
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return block }
        return "\(trimmedBody)\n\n\(block)"
    }

    static func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func makeULID(date: Date = Date()) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var time = UInt64(date.timeIntervalSince1970 * 1000)
        var chars = Array(repeating: Character("0"), count: 26)
        for index in stride(from: 9, through: 0, by: -1) {
            chars[index] = alphabet[Int(time & 31)]
            time >>= 5
        }
        var random = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        var bitBuffer: UInt16 = 0
        var bitCount = 0
        var outIndex = 10
        for byte in random {
            bitBuffer = (bitBuffer << 8) | UInt16(byte)
            bitCount += 8
            while bitCount >= 5 && outIndex < 26 {
                let shift = bitCount - 5
                chars[outIndex] = alphabet[Int((bitBuffer >> UInt16(shift)) & 31)]
                bitCount -= 5
                bitBuffer &= UInt16((1 << bitCount) - 1)
                outIndex += 1
            }
        }
        return String(chars)
    }
}
