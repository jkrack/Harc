import CryptoKit
import Foundation

/// A deterministic projection of opaque cluster IDs within one exact artifact.
/// This is an identity binding, not proof of producer authentication or selection.
/// Admission must independently establish those facts before using this map.
public struct SpeakerClusterMap: Codable, Equatable, Hashable, Sendable {
    public let canonicalRecordingID: CanonicalRecordingID
    public let canonicalPCMHash: CanonicalPCMHash
    public let producerDeviceID: DeviceID
    public let processingArtifactSHA256: Data
    public let localClusterIDs: [String]

    public init(canonicalRecordingID: CanonicalRecordingID, canonicalPCMHash: CanonicalPCMHash,
                producerDeviceID: DeviceID, processingArtifactSHA256: Data,
                localClusterIDs: [String]) throws {
        guard processingArtifactSHA256.count == 32 else {
            throw DomainValidationError.invalidDigestLength(field: "SpeakerClusterMap.artifact",
                expected: 32, actual: processingArtifactSHA256.count)
        }
        guard UInt32(exactly: localClusterIDs.count) != nil,
              Set(localClusterIDs).count == localClusterIDs.count else {
            throw DomainValidationError.invalidState(reason: "Speaker cluster IDs must be unique and bounded")
        }
        for cluster in localClusterIDs {
            guard !cluster.isEmpty, cluster.utf8.count <= 128,
                  cluster == cluster.trimmingCharacters(in: .whitespacesAndNewlines),
                  cluster.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
                throw DomainValidationError.invalidCode(field: "SpeakerClusterMap.localClusterID")
            }
        }
        self.canonicalRecordingID = canonicalRecordingID
        self.canonicalPCMHash = canonicalPCMHash
        self.producerDeviceID = producerDeviceID
        self.processingArtifactSHA256 = processingArtifactSHA256
        self.localClusterIDs = localClusterIDs.sorted()
    }

    /// Never interpret a client's numeric-looking cluster ID as a Host index.
    public func canonicalSpeakerIndex(for evidence: SpeakerEvidenceSnapshot) throws -> UInt32 {
        guard evidence.canonicalRecordingID == canonicalRecordingID,
              evidence.canonicalPCMHash == canonicalPCMHash,
              evidence.producerDeviceID == producerDeviceID,
              evidence.processingArtifactSHA256 == processingArtifactSHA256,
              let index = localClusterIDs.firstIndex(of: evidence.localClusterID),
              let result = UInt32(exactly: index) else {
            throw DomainValidationError.invalidState(reason: "Speaker evidence does not belong to this artifact's cluster map")
        }
        return result
    }

    public var mappingSHA256: Data {
        var material = Data("harc-speaker-cluster-map-v1\0".utf8)
        func append(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
            material.append(data)
        }
        append(Data(canonicalRecordingID.description.utf8))
        append(canonicalPCMHash.rawBytes)
        append(producerDeviceID.rawBytes)
        append(processingArtifactSHA256)
        for cluster in localClusterIDs { append(Data(cluster.utf8)) }
        return Data(SHA256.hash(data: material))
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalRecordingID, canonicalPCMHash, producerDeviceID, processingArtifactSHA256, localClusterIDs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(canonicalRecordingID: values.decode(CanonicalRecordingID.self, forKey: .canonicalRecordingID),
            canonicalPCMHash: values.decode(CanonicalPCMHash.self, forKey: .canonicalPCMHash),
            producerDeviceID: values.decode(DeviceID.self, forKey: .producerDeviceID),
            processingArtifactSHA256: values.decode(Data.self, forKey: .processingArtifactSHA256),
            localClusterIDs: values.decode([String].self, forKey: .localClusterIDs))
    }
}
