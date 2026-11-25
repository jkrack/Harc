import Foundation

public enum HarcVersion {
    /// Marketing version, read from the running bundle.
    ///
    /// This used to be a hand-maintained string literal, and it drifted: it
    /// still said `0.2.17` while `project.yml` shipped `0.7.3`, so the menu-bar
    /// panel footer, `harc-stt --version`, and the daemon's `status` response
    /// all reported a version five minor releases stale. Reading
    /// `CFBundleShortVersionString` — which xcodegen fills from
    /// `MARKETING_VERSION` — makes drift impossible for the app and for the
    /// daemon, whose executable lives inside `Harc.app/Contents/MacOS`.
    public static let current: String = {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let short, !short.isEmpty else { return fallbackVersion }
        return short
    }()

    /// Used only where there is no Harc bundle to read — unit tests run inside
    /// the xctest runner. `VersionTests` asserts this stays equal to
    /// `project.yml`'s `MARKETING_VERSION`, which is the check that would have
    /// caught the original drift.
    public static let fallbackVersion = "0.14.24"

    /// Engine identity, not an Apple asset revision: OS-managed model revisions
    /// are not exposed. Legacy engines require explicit selection.
    public static var sttEngineVersion: String {
        sttModelID(engine: ProcessInfo.processInfo.environment["HARC_STT_ASR_ENGINE"])
    }

    public static func sttModelID(engine: String?) -> String {
        switch engine {
        case "v2": return "parakeet-tdt-0.6b-v2"
        case "unified": return "parakeet-unified-en-0.6b"
        default: return "apple-speech-transcriber"
        }
    }
}
