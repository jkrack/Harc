import Foundation

/// Share a dictation mode as a `.harcmode` JSON file. Pure encode/decode —
/// the save/open panels live in the settings view.
public enum DictationModeIO {
    public static let fileExtension = "harcmode"

    public enum ImportError: LocalizedError {
        case undecodable

        public var errorDescription: String? {
            "Not a valid Harc dictation mode file."
        }
    }

    public static func exportData(_ mode: DictationMode) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(mode)
    }

    /// Decode a shared mode. Imported modes are always user modes
    /// (never built-in) and get a fresh id when theirs collides with an
    /// existing mode.
    public static func importMode(from data: Data, existingIDs: Set<String>) throws -> DictationMode {
        guard var mode = try? JSONDecoder().decode(DictationMode.self, from: data) else {
            throw ImportError.undecodable
        }
        mode.isBuiltIn = false
        if existingIDs.contains(mode.id) {
            mode.id = UUID().uuidString
        }
        return mode
    }
}
