import Foundation
import GRDB

/// Host-local storage reference. Never serialize these paths into a network DTO.
public struct SelectedEdgeArtifactSource: Sendable, Equatable {
    public let signedMetadataURL: URL
    public let bundleURL: URL
    public let signedMetadataSHA256: Data
    public let bundleSHA256: Data

    public init(signedMetadataURL: URL, bundleURL: URL, signedMetadataSHA256: Data, bundleSHA256: Data) throws {
        guard signedMetadataURL.isFileURL, bundleURL.isFileURL,
              signedMetadataSHA256.count == 32, bundleSHA256.count == 32 else {
            throw StoreError.invalidData("Invalid local selected artifact reference")
        }
        self.signedMetadataURL = signedMetadataURL
        self.bundleURL = bundleURL
        self.signedMetadataSHA256 = signedMetadataSHA256
        self.bundleSHA256 = bundleSHA256
    }

    internal func verifyFiles() throws {
        guard try RecordingStore.speakerArtifactDigest(path: signedMetadataURL.path) == signedMetadataSHA256,
              try RecordingStore.speakerArtifactDigest(path: bundleURL.path) == bundleSHA256 else {
            throw StoreError.invalidData("Selected processing artifact bytes changed")
        }
    }
}

public extension RecordingStore {
    /// Resolve only the currently selected, ready artifact and verify both files.
    /// Consumers must hash the actual bytes they decode again after this lookup.
    func selectedEdgeArtifactSource(recordingID: Int64) async throws -> SelectedEdgeArtifactSource? {
        try await db.read { database in
            try Self.selectedEdgeArtifactSource(in: database, recordingID: recordingID)
        }
    }

    internal static func selectedEdgeArtifactSource(in database: Database, recordingID: Int64) throws -> SelectedEdgeArtifactSource? {
            guard let map = try Self.selectedSpeakerClusterMap(in: database, recordingID: recordingID),
                  let row = try Row.fetchOne(database, sql:
                    "SELECT * FROM selected_edge_artifact_source WHERE recording_id = ?",
                    arguments: [recordingID]) else { return nil }
            let source = try SelectedEdgeArtifactSource(
                signedMetadataURL: URL(fileURLWithPath: row["signed_metadata_path"]),
                bundleURL: URL(fileURLWithPath: row["bundle_path"]),
                signedMetadataSHA256: row["signed_metadata_sha256"], bundleSHA256: row["bundle_sha256"])
            guard source.bundleSHA256 == map.processingArtifactSHA256 else {
                throw StoreError.invalidData("Selected processing artifact reference does not match its map")
            }
            try source.verifyFiles()
            return source
    }
}
