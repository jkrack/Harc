import Foundation

public enum WikiSection: String, Sendable, Codable, Equatable, Hashable, CaseIterable, Identifiable {
    case overview
    case index
    case topics
    case people
    case projects
    case sources
    case decisions
    case contradictions
    case openQuestions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .index: return "Index"
        case .topics: return "Topics"
        case .people: return "People"
        case .projects: return "Projects"
        case .sources: return "Sources"
        case .decisions: return "Decisions"
        case .contradictions: return "Contradictions"
        case .openQuestions: return "Open Questions"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: return "sparkles"
        case .index: return "list.bullet.rectangle"
        case .topics: return "tag"
        case .people: return "person.2"
        case .projects: return "folder"
        case .sources: return "tray.full"
        case .decisions: return "checkmark.seal"
        case .contradictions: return "exclamationmark.triangle"
        case .openQuestions: return "questionmark.circle"
        }
    }
}

public struct WikiPage: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var section: WikiSection
    public var fileURL: URL
    public var body: String
    public var updatedAt: Date

    public init(id: String, title: String, section: WikiSection, fileURL: URL, body: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.section = section
        self.fileURL = fileURL
        self.body = body
        self.updatedAt = updatedAt
    }
}

public actor HarcWikiStore {
    public let rootURL: URL

    public init(rootURL: URL = HarcWikiStore.defaultURL()) {
        self.rootURL = rootURL
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc/Wiki", isDirectory: true)
    }

    public func fetchPages(section: WikiSection? = nil) async throws -> [WikiPage] {
        try ensureRoot()
        let urls = try markdownFileURLs()
        let pages = try urls.map(loadPage)
        let filtered = section.map { target in pages.filter { $0.section == target } } ?? pages
        return filtered.sorted {
            if $0.section != $1.section {
                let leftIndex = WikiSection.allCases.firstIndex(of: $0.section) ?? 0
                let rightIndex = WikiSection.allCases.firstIndex(of: $1.section) ?? 0
                return leftIndex < rightIndex
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    public func fetchPage(id: String) async throws -> WikiPage? {
        try await fetchPages().first { $0.id == id }
    }

    @discardableResult
    public func writePage(section: WikiSection, title: String, body: String) async throws -> WikiPage {
        try ensureRoot()
        let sectionURL = rootURL.appendingPathComponent(section.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: sectionURL, withIntermediateDirectories: true)
        let filename = Self.slug(title).isEmpty ? "untitled" : Self.slug(title)
        let url = sectionURL.appendingPathComponent("\(filename).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return WikiPage(
            id: "\(section.rawValue)/\(filename)",
            title: title,
            section: section,
            fileURL: url,
            body: body,
            updatedAt: attrs[.modificationDate] as? Date ?? Date()
        )
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
                  url.pathExtension.lowercased() == "md",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else {
                return nil
            }
            return url
        }
    }

    private func loadPage(_ url: URL) throws -> WikiPage {
        let body = try String(contentsOf: url, encoding: .utf8)
        let sectionName = url.deletingLastPathComponent().lastPathComponent
        let section = WikiSection(rawValue: sectionName) ?? .topics
        let title = Self.title(from: body) ?? url.deletingPathExtension().lastPathComponent
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return WikiPage(
            id: "\(section.rawValue)/\(url.deletingPathExtension().lastPathComponent)",
            title: title,
            section: section,
            fileURL: url,
            body: body,
            updatedAt: attrs[.modificationDate] as? Date ?? Date()
        )
    }

    private static func title(from body: String) -> String? {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public static func slug(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
