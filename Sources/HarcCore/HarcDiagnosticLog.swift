import Combine
import Foundation

public enum HarcDiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case success
    case warning
    case error
}

/// One privacy-bounded operational event. Callers may attach identifiers and
/// numeric facts, but must never include audio, transcript text, credentials,
/// authorization metadata, pairing secrets, or full filesystem paths.
public struct HarcDiagnosticLogEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let severity: HarcDiagnosticSeverity
    public let area: String
    public let stage: String
    public let message: String
    public let context: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: HarcDiagnosticSeverity,
        area: String,
        stage: String,
        message: String,
        context: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.area = area
        self.stage = stage
        self.message = message
        self.context = context
    }
}

/// A small crash-safe JSONL log intended for user-assisted troubleshooting.
/// The whole bounded payload is atomically replaced for every event. Client
/// transfer events are infrequent, and the atomic boundary is more valuable
/// here than maximizing append throughput.
@MainActor
public final class HarcDiagnosticLogStore: ObservableObject {
    @Published public private(set) var entries: [HarcDiagnosticLogEntry]

    public let fileURL: URL
    public let maximumEntries: Int

    public init(
        fileURL: URL,
        maximumEntries: Int = 300
    ) throws {
        precondition(maximumEntries > 0)
        self.fileURL = fileURL.standardizedFileURL
        self.maximumEntries = maximumEntries
        let directory = self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        entries = try Self.load(from: self.fileURL)
        if entries.count > maximumEntries {
            entries = Array(entries.suffix(maximumEntries))
            try persist()
        }
    }

    @discardableResult
    public func append(
        severity: HarcDiagnosticSeverity,
        area: String,
        stage: String,
        message: String,
        context: [String: String] = [:],
        at timestamp: Date = Date()
    ) -> HarcDiagnosticLogEntry {
        var boundedContext: [String: String] = [:]
        for key in context.keys.sorted().prefix(12) {
            boundedContext[Self.bounded(key, limit: 64)] = Self.bounded(
                context[key] ?? "",
                limit: 512
            )
        }
        let entry = HarcDiagnosticLogEntry(
            timestamp: timestamp,
            severity: severity,
            area: Self.bounded(area, limit: 64),
            stage: Self.bounded(stage, limit: 64),
            message: Self.bounded(message, limit: 1_024),
            context: boundedContext
        )
        entries.append(entry)
        if entries.count > maximumEntries {
            entries.removeFirst(entries.count - maximumEntries)
        }
        do {
            try persist()
        } catch {
            // The in-memory event remains visible. Logging must never abort a
            // recording, recovery pass, or transfer retry.
        }
        return entry
    }

    public func clear() {
        entries = []
        do {
            try persist()
        } catch {
            // Clearing a diagnostic aid must not affect Client operation.
        }
    }

    public func formattedText(
        product: String = "Harc Client diagnostic log"
    ) -> String {
        Self.formattedText(entries: entries, product: product)
    }

    public static func formattedText(
        entries: [HarcDiagnosticLogEntry],
        product: String = "Harc Client diagnostic log"
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [product, "Events: \(entries.count)", ""]
        for entry in entries {
            var line = "\(formatter.string(from: entry.timestamp)) [\(entry.severity.rawValue.uppercased())] \(entry.area).\(entry.stage) — \(entry.message)"
            if !entry.context.isEmpty {
                let facts = entry.context.keys.sorted().map {
                    "\($0)=\(entry.context[$0] ?? "")"
                }
                line += " | " + facts.joined(separator: " ")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0a)
        }
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func load(from url: URL) throws -> [HarcDiagnosticLogEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return data.split(separator: 0x0a).compactMap {
            try? decoder.decode(HarcDiagnosticLogEntry.self, from: Data($0))
        }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }
}
