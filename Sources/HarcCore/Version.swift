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
    public static let fallbackVersion = "0.14.3"

    /// Identity of the speech engine, stamped onto every transcript as
    /// provenance. Bump this whenever a change would alter transcription
    /// output — a new Parakeet build, different decoding — so existing
    /// recordings correctly register as re-transcribable.
    public static let sttEngineVersion = "tdt-0.6b-v3"
}
