import Foundation

/// A newer Harc release Sparkle has discovered. HarcUI stays Sparkle-free:
/// the app target's updater delegate publishes this onto `HarcAppBridge`,
/// and UI actions route back through the bridge's update closures.
public struct AvailableUpdate: Equatable, Sendable {
    /// Display version, e.g. "0.6.0".
    public let version: String
    /// Release page — fallback destination when the installer can't run.
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}
