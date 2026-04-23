import Foundation

/// On-disk layout for the model shelf.
///
/// ```
/// ~/Library/Application Support/Harc/
///   Models/
///     <model-id>/
///       config.json
///       model.safetensors
///       …
///       .harc-install.json      ← present iff fully installed + verified
///       .harc-download.partial  ← present iff a download is in flight / paused
/// ```
///
/// The two dotfiles are source of truth:
/// - `.harc-install.json` exists → model is installed.
/// - `.harc-download.partial` exists → resume data available.
/// - Neither → model is absent.
///
/// Start-of-download clears any prior install; completion writes the install
/// marker and removes the partial marker.
public struct ModelStorage: Sendable {
    public static let installMarkerName = ".harc-install.json"
    public static let partialMarkerName = ".harc-download.partial"

    /// Root `~/Library/Application Support/Harc/Models`. Injectable for tests.
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Default base under the user's Application Support dir. Falls back to
    /// `NSTemporaryDirectory` only if the OS can't resolve Application Support
    /// (essentially never in practice).
    public static func defaultBase() -> URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return appSupport
            .appendingPathComponent("Harc", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Paths

    public func modelDirectory(for id: String) -> URL {
        baseDirectory.appendingPathComponent(id, isDirectory: true)
    }

    public func fileURL(forDescriptor d: ModelDescriptor, file: ModelFile) -> URL {
        modelDirectory(for: d.id).appendingPathComponent(file.path)
    }

    public func installMarker(for id: String) -> URL {
        modelDirectory(for: id).appendingPathComponent(Self.installMarkerName)
    }

    public func partialMarker(for id: String) -> URL {
        modelDirectory(for: id).appendingPathComponent(Self.partialMarkerName)
    }

    // MARK: - Directory management

    /// Idempotent. Creates `Models/<id>/` if missing.
    public func ensureModelDirectory(for id: String) throws {
        let dir = modelDirectory(for: id)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
    }

    /// Remove the model's directory entirely. Swallows `noSuchFile` —
    /// callers that need to know whether anything existed should check
    /// `state(of:)` first.
    public func removeModelDirectory(for id: String) throws {
        let dir = modelDirectory(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        try fm.removeItem(at: dir)
    }

    // MARK: - Install marker

    public struct InstallRecord: Codable, Equatable, Sendable {
        public let modelID: String
        public let revision: String
        public let installedAt: Date
        public let bytes: Int64
        /// Set to true when any file's SHA was not validated (because the
        /// catalog entry shipped with an empty sha256). Informational only —
        /// we still count the install as complete; the dotfile records the
        /// honesty-level so the UI can show a subtle "unverified" chip.
        public let skippedSHAVerification: Bool

        public init(
            modelID: String,
            revision: String,
            installedAt: Date = Date(),
            bytes: Int64,
            skippedSHAVerification: Bool
        ) {
            self.modelID = modelID
            self.revision = revision
            self.installedAt = installedAt
            self.bytes = bytes
            self.skippedSHAVerification = skippedSHAVerification
        }
    }

    public func readInstallRecord(for id: String) -> InstallRecord? {
        let url = installMarker(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.harc.decode(InstallRecord.self, from: data)
    }

    public func writeInstallRecord(_ record: InstallRecord) throws {
        try ensureModelDirectory(for: record.modelID)
        let url = installMarker(for: record.modelID)
        let data = try JSONEncoder.harc.encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func clearInstallRecord(for id: String) throws {
        let url = installMarker(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    // MARK: - Partial download marker

    public struct PartialRecord: Codable, Equatable, Sendable {
        public struct FileState: Codable, Equatable, Sendable {
            public let path: String
            /// Bytes already on disk at `path.part`.
            public let bytesDone: Int64
            /// URLSession resume payload, when available.
            public let resumeData: Data?

            public init(path: String, bytesDone: Int64, resumeData: Data?) {
                self.path = path
                self.bytesDone = bytesDone
                self.resumeData = resumeData
            }
        }
        public let modelID: String
        public let revision: String
        public let startedAt: Date
        public let files: [FileState]

        public init(
            modelID: String,
            revision: String,
            startedAt: Date = Date(),
            files: [FileState]
        ) {
            self.modelID = modelID
            self.revision = revision
            self.startedAt = startedAt
            self.files = files
        }
    }

    public func readPartialRecord(for id: String) -> PartialRecord? {
        let url = partialMarker(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.harc.decode(PartialRecord.self, from: data)
    }

    public func writePartialRecord(_ record: PartialRecord) throws {
        try ensureModelDirectory(for: record.modelID)
        let url = partialMarker(for: record.modelID)
        let data = try JSONEncoder.harc.encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func clearPartialRecord(for id: String) throws {
        let url = partialMarker(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
    }

    // MARK: - State derivation

    /// Derives the install state from disk dotfiles. The `ModelManager` owns
    /// the in-flight `.downloading` / `.verifying` / `.failed` transitions;
    /// this only distinguishes persistent states (`.absent` / `.installed`).
    public func persistedState(for id: String) -> ModelInstallState {
        if readInstallRecord(for: id) != nil {
            return .installed
        }
        return .absent
    }
}

// MARK: - JSON coders

extension JSONEncoder {
    static let harc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
}

extension JSONDecoder {
    static let harc: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
