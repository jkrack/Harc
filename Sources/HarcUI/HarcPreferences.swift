import Foundation
import Combine

/// App-wide preferences backed by UserDefaults. SwiftUI views observe.
@MainActor
public final class HarcPreferences: ObservableObject {
    private enum Key {
        static let destinationPath = "harc.destinationPath"
        static let diarize = "harc.diarize"
        static let chunkDurationSeconds = "harc.chunkDurationSeconds"
    }

    @Published public var destinationPath: String {
        didSet { UserDefaults.standard.set(destinationPath, forKey: Key.destinationPath) }
    }

    @Published public var diarize: Bool {
        didSet { UserDefaults.standard.set(diarize, forKey: Key.diarize) }
    }

    @Published public var chunkDurationSeconds: Double {
        didSet { UserDefaults.standard.set(chunkDurationSeconds, forKey: Key.chunkDurationSeconds) }
    }

    public static let shared = HarcPreferences()

    public init() {
        let defaults = UserDefaults.standard
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Harc").path
        self.destinationPath = defaults.string(forKey: Key.destinationPath) ?? defaultPath
        self.diarize = defaults.object(forKey: Key.diarize) as? Bool ?? true
        self.chunkDurationSeconds = defaults.object(forKey: Key.chunkDurationSeconds) as? Double ?? 60.0
    }

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath, isDirectory: true)
    }
}
