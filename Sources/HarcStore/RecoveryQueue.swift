import Foundation

public struct RecoveryArtifact: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case interruptedWAV
        case finalizedMissingDatabaseRow
        case timeoutFinalizing
        case destinationMoveFailed
        case noteLinkFailed
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case recovering
        case recovered
        case skipped
        case discarded
        case failed
    }

    public var id: String
    public var kind: Kind
    public var status: Status
    public var sourceURL: URL
    public var destinationURL: URL?
    public var recordingID: Int64?
    public var title: String
    public var detail: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastError: String?

    public init(
        id: String,
        kind: Kind,
        status: Status = .pending,
        sourceURL: URL,
        destinationURL: URL? = nil,
        recordingID: Int64? = nil,
        title: String,
        detail: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.recordingID = recordingID
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

public actor RecoveryQueue {
    public enum QueueError: Error, LocalizedError, Sendable {
        case artifactNotFound(String)
        case missingDestination(String)

        public var errorDescription: String? {
            switch self {
            case .artifactNotFound(let id):
                return "Recovery artifact \(id) was not found."
            case .missingDestination(let id):
                return "Recovery artifact \(id) does not have a destination directory."
            }
        }
    }

    public let fileURL: URL
    private let store: RecordingStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var artifacts: [RecoveryArtifact] = []
    private var loaded = false

    public init(fileURL: URL, store: RecordingStore) {
        self.fileURL = fileURL
        self.store = store

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public static func defaultURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harc/recovery.json")
    }

    public static func deterministicID(for sourceURL: URL, fileSize: Int, modifiedAt: Date?) -> String {
        let modified = modifiedAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return "interruptedWAV:\(sourceURL.standardizedFileURL.path):\(fileSize):\(modified)"
    }

    public func scanCache(cacheDirectory: URL, destinationDirectory: URL) async throws {
        try loadIfNeeded()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var changed = false
        for url in files where url.pathExtension.lowercased() == "wav" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fileSize = values?.fileSize ?? 0
            guard fileSize > 0 else { continue }
            if try await store.fetchByWavPath(url.path) != nil { continue }

            let id = Self.deterministicID(
                for: url,
                fileSize: fileSize,
                modifiedAt: values?.contentModificationDate
            )
            guard artifacts.firstIndex(where: { $0.id == id }) == nil else { continue }

            artifacts.append(
                RecoveryArtifact(
                    id: id,
                    kind: .interruptedWAV,
                    sourceURL: url,
                    destinationURL: destinationDirectory,
                    title: "Interrupted recording",
                    detail: "\(fileSize) bytes in cache"
                )
            )
            changed = true
        }

        if changed {
            try persist()
        }
    }

    public func enqueue(_ artifact: RecoveryArtifact) async throws {
        try loadIfNeeded()
        if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[index] = merge(existing: artifacts[index], incoming: artifact)
        } else {
            artifacts.append(artifact)
        }
        try persist()
    }

    public func fetchAll() async throws -> [RecoveryArtifact] {
        try loadIfNeeded()
        return artifacts.sorted { lhs, rhs in
            if lhs.status == rhs.status {
                return lhs.createdAt > rhs.createdAt
            }
            return statusRank(lhs.status) < statusRank(rhs.status)
        }
    }

    @discardableResult
    public func recover(id: String) async throws -> RecoveryArtifact {
        try loadIfNeeded()
        guard let index = artifacts.firstIndex(where: { $0.id == id }) else {
            throw QueueError.artifactNotFound(id)
        }
        if artifacts[index].status == .recovered {
            return artifacts[index]
        }
        guard let destination = artifacts[index].destinationURL else {
            throw QueueError.missingDestination(id)
        }

        artifacts[index].status = .recovering
        artifacts[index].updatedAt = Date()
        artifacts[index].lastError = nil
        try persist()

        do {
            let recovery = RecordingCacheRecovery(
                cacheDirectory: artifacts[index].sourceURL.deletingLastPathComponent(),
                destinationDirectory: destination,
                store: store
            )
            let recording = try await recovery.recover(artifacts[index].sourceURL)
            artifacts[index].status = .recovered
            artifacts[index].destinationURL = URL(fileURLWithPath: recording.wavPath)
            artifacts[index].recordingID = recording.id
            artifacts[index].updatedAt = Date()
            artifacts[index].lastError = nil
        } catch {
            artifacts[index].status = .failed
            artifacts[index].updatedAt = Date()
            artifacts[index].lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        try persist()
        return artifacts[index]
    }

    @discardableResult
    public func discard(id: String) async throws -> RecoveryArtifact {
        try loadIfNeeded()
        guard let index = artifacts.firstIndex(where: { $0.id == id }) else {
            throw QueueError.artifactNotFound(id)
        }
        artifacts[index].status = .discarded
        artifacts[index].updatedAt = Date()
        artifacts[index].lastError = nil
        try persist()
        return artifacts[index]
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            artifacts = []
            return
        }
        let data = try Data(contentsOf: fileURL)
        artifacts = try decoder.decode([RecoveryArtifact].self, from: data)
    }

    private func persist() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try encoder.encode(artifacts)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func merge(existing: RecoveryArtifact, incoming: RecoveryArtifact) -> RecoveryArtifact {
        var merged = incoming
        merged.createdAt = existing.createdAt
        if existing.status == .recovered || existing.status == .discarded {
            merged.status = existing.status
            merged.recordingID = existing.recordingID
            merged.destinationURL = existing.destinationURL
            merged.lastError = existing.lastError
        }
        return merged
    }

    private func statusRank(_ status: RecoveryArtifact.Status) -> Int {
        switch status {
        case .pending, .recovering, .failed:
            return 0
        case .recovered:
            return 1
        case .skipped:
            return 2
        case .discarded:
            return 3
        }
    }
}
