import Foundation

public enum WikiReviewProposalKind: String, Sendable, Codable, Equatable, CaseIterable {
    case createPage
    case updatePage
    case addBacklink
    case flagContradiction
    case markStale
}

public enum WikiReviewProposalStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case pending
    case edited
    case approved
    case dismissed
    case failed
}

public struct WikiReviewProposal: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var kind: WikiReviewProposalKind
    public var status: WikiReviewProposalStatus
    public var title: String
    public var summary: String
    public var targetSection: WikiSection
    public var targetTitle: String
    public var proposedMarkdown: String
    public var sourceCitations: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: WikiReviewProposalKind,
        status: WikiReviewProposalStatus = .pending,
        title: String,
        summary: String,
        targetSection: WikiSection,
        targetTitle: String,
        proposedMarkdown: String,
        sourceCitations: [String],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.summary = summary
        self.targetSection = targetSection
        self.targetTitle = targetTitle
        self.proposedMarkdown = proposedMarkdown
        self.sourceCitations = sourceCitations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public actor WikiReviewStore {
    public let fileURL: URL
    private let wikiStore: HarcWikiStore
    private let wikiMerger: WikiMerger

    public init(
        fileURL: URL = WikiReviewStore.defaultURL(),
        wikiStore: HarcWikiStore = HarcWikiStore()
    ) {
        self.fileURL = fileURL
        self.wikiStore = wikiStore
        self.wikiMerger = WikiMerger(wikiStore: wikiStore)
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc/Wiki/.review/proposals.json")
    }

    public func fetchAll() async throws -> [WikiReviewProposal] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.harcReview.decode([WikiReviewProposal].self, from: data)
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func upsert(_ proposal: WikiReviewProposal) async throws -> WikiReviewProposal {
        var all = try await fetchAll()
        var next = proposal
        next.updatedAt = Date()
        if let index = all.firstIndex(where: { $0.id == next.id }) {
            all[index] = next
        } else {
            all.append(next)
        }
        try write(all)
        return next
    }

    @discardableResult
    public func updateStatus(id: String, status: WikiReviewProposalStatus) async throws -> WikiReviewProposal {
        var all = try await fetchAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw WikiReviewStoreError.proposalNotFound(id)
        }
        all[index].status = status
        all[index].updatedAt = Date()
        try write(all)
        return all[index]
    }

    @discardableResult
    public func approve(id: String) async throws -> WikiReviewProposal {
        var all = try await fetchAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw WikiReviewStoreError.proposalNotFound(id)
        }
        do {
            _ = try await wikiMerger.merge(all[index])
            all[index].status = .approved
        } catch {
            all[index].status = .failed
        }
        all[index].updatedAt = Date()
        try write(all)
        return all[index]
    }

    private func write(_ proposals: [WikiReviewProposal]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.harcReview.encode(proposals.sorted { $0.createdAt > $1.createdAt })
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum WikiReviewStoreError: Error, Equatable, Sendable {
    case proposalNotFound(String)
}

private extension JSONEncoder {
    static var harcReview: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var harcReview: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
