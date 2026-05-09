import Foundation

/// Local-only text embedding boundary.
///
/// Production implementations must load an on-device model through Harc's
/// model manager. This protocol intentionally has no URL/session/request
/// surface; cloud embedding clients do not belong behind this abstraction.
public protocol LocalTextEmbedder: Sendable {
    var modelID: String { get }
    func embed(texts: [String]) async throws -> [Data]
}
