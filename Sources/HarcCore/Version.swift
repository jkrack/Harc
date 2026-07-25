public enum HarcVersion {
    public static let current = "0.2.17"

    /// Identity of the speech engine, stamped onto every transcript as
    /// provenance. Bump this whenever a change would alter transcription
    /// output — a new Parakeet build, different decoding — so existing
    /// recordings correctly register as re-transcribable.
    public static let sttEngineVersion = "tdt-0.6b-v3"
}
