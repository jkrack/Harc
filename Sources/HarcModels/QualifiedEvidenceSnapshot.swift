import Foundation
import CryptoKit

/// A scoped verified copy of a fixed catalog bundle. Not a resident-model
/// attestation. Only the factory can construct this value; consumers must not
/// retain its directory beyond the callback's lifetime.
public struct QualifiedEvidenceSnapshot: Sendable {
    public let context: QualifiedEvidenceContext
    public let manifestDigest: String
    public let nonce: UUID
    public var directory: URL { context.directory }
    fileprivate init(context: QualifiedEvidenceContext, manifestDigest: String) {
        self.context = context; self.manifestDigest = manifestDigest; nonce = UUID()
    }
}

public enum QualifiedEvidenceSnapshotFactory {
    /// No network or installation. The source must already contain the exact
    /// catalog bundle. Unknown loader inputs fail closed. Original files remain
    /// untouched. Caller must unload its container before this scope returns.
    public static func withSnapshot<T: Sendable>(modelID: String, installedDirectory: URL,
        scratchDirectory: URL, consume: @Sendable (QualifiedEvidenceSnapshot) async throws -> T) async throws -> T {
        guard modelID == "gemma-4-e2b-it-4bit",
              let descriptor = ModelCatalog.descriptor(for: modelID), descriptor.manifestVerified,
              descriptor.files.count <= 16, descriptor.totalBytes <= 4_294_967_296 else {
            throw EvidenceContextError.unsupportedModel
        }
        // Resolve before potentially copying gigabytes; still recheck the copy.
        _ = try await EvidenceContextQualification.resolve(modelID: modelID, directory: installedDirectory)
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: scratchDirectory.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value > descriptor.totalBytes + 67_108_864 else {
            throw EvidenceContextError.invalidConfig
        }
        let files = descriptor.files.map {
            SyntheticEvidenceSnapshot.File(name: $0.path, bytes: Int($0.bytes), sha256: $0.sha256)
        }
        let manifest = descriptor.files.sorted { $0.path < $1.path }.map {
            "\($0.path)\t\($0.bytes)\t\($0.sha256)"
        }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data((descriptor.id + "\n" + descriptor.revision + "\n" + manifest).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return try await SyntheticEvidenceSnapshot.withSnapshot(source: installedDirectory, scratch: scratchDirectory,
            files: files, maximumFileBytes: 4_294_967_296, maximumTotalBytes: 4_294_967_296,
            ignoredSourceNames: [ModelStorage.installMarkerName, ModelStorage.partialMarkerName]) { directory in
                let context = try await EvidenceContextQualification.resolve(modelID: modelID, directory: directory)
                return try await consume(QualifiedEvidenceSnapshot(context: context, manifestDigest: digest))
            }
    }
}
