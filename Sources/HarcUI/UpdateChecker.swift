import Foundation
import Combine
import HarcCore

/// A newer Harc release discovered on GitHub.
public struct AvailableUpdate: Equatable, Sendable {
    /// Normalized version without the leading "v", e.g. "0.5.0".
    public let version: String
    /// Release page to open in the browser.
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Three-component semantic version parsed from a release tag ("v0.10.0")
/// or a bundle version string ("0.10.0"). Missing components pad to zero
/// ("1.2" → 1.2.0); prerelease/build suffixes are dropped; anything
/// non-numeric is malformed and parses to nil.
struct UpdateSemVer: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var display: String { "\(major).\(minor).\(patch)" }
}

/// Lightweight GitHub-releases update check — no Sparkle, no appcast.
/// Fetches the latest release tag (unauthenticated, ETag-cached) at most
/// once a day, compares it against the running version, and publishes an
/// `AvailableUpdate` when a newer tag exists. Network failures are logged
/// and otherwise silent — offline users are never nagged.
///
/// Session, clock, defaults, and version are all injectable for tests.
@MainActor
public final class UpdateChecker: ObservableObject {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Inline status for the Settings "Check for Updates" button.
    public enum CheckStatus: Equatable {
        case checking
        case upToDate
        case updateAvailable(AvailableUpdate)
        case failed
    }

    private enum Key {
        static let lastCheckedAt = "harc.update.lastCheckedAt"
        static let etag = "harc.update.etag"
        static let latestVersion = "harc.update.latestVersion"
        static let latestURL = "harc.update.latestURL"
    }

    public static let shared = UpdateChecker()

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/jkrack/Harc/releases/latest")!
    static let fallbackReleasePage = URL(string: "https://github.com/jkrack/Harc/releases/latest")!

    /// Newer release than the running version, if one is known. Persisted
    /// across launches so the menu-bar row survives a restart offline.
    @Published public private(set) var availableUpdate: AvailableUpdate?
    /// Result of the last manual "Check for Updates" press. nil until used.
    @Published public private(set) var manualCheckStatus: CheckStatus?

    private let currentVersion: String
    private let fetch: Fetch
    private let now: () -> Date
    private let defaults: UserDefaults
    private let updatesEnabled: () -> Bool
    private let minimumCheckInterval: TimeInterval
    private var loopTask: Task<Void, Never>?

    /// - Parameters:
    ///   - currentVersion: The running version. Defaults to the main
    ///     bundle's `CFBundleShortVersionString`, falling back to
    ///     `HarcVersion.current` when run outside an app bundle.
    ///   - updatesEnabled: Gate for scheduled checks. Defaults to the
    ///     `updateChecksEnabled` preference.
    public init(
        currentVersion: String? = nil,
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        updatesEnabled: (() -> Bool)? = nil,
        minimumCheckInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? HarcVersion.current
        self.fetch = fetch
        self.now = now
        self.defaults = defaults
        self.updatesEnabled = updatesEnabled ?? { HarcPreferences.shared.updateChecksEnabled }
        self.minimumCheckInterval = minimumCheckInterval
        // Surface a previously discovered update without touching the
        // network — and clear it if the user has since upgraded past it.
        if let cachedTag = defaults.string(forKey: Key.latestVersion) {
            self.availableUpdate = Self.update(
                fromTag: cachedTag,
                urlString: defaults.string(forKey: Key.latestURL),
                current: self.currentVersion
            )
        }
    }

    /// Launch wiring: first check shortly after startup (non-blocking),
    /// then re-evaluate hourly — the daily throttle decides whether a
    /// request actually fires. Safe to call once; later calls no-op.
    public func start(initialDelay: TimeInterval = 15, resyncInterval: TimeInterval = 60 * 60) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                guard let checker = self else { break }
                await checker.checkIfDue()
                try? await Task.sleep(for: .seconds(resyncInterval))
            }
        }
    }

    /// Scheduled path — respects the pref and the once-a-day throttle.
    public func checkIfDue() async {
        guard updatesEnabled() else { return }
        if let last = defaults.object(forKey: Key.lastCheckedAt) as? Date,
           now().timeIntervalSince(last) < minimumCheckInterval {
            return
        }
        _ = await performCheck()
    }

    /// Manual "Check for Updates" — pressing the button is explicit
    /// consent, so this bypasses both the throttle and the pref, and
    /// reports an inline status for the Settings row.
    public func checkNow() async {
        manualCheckStatus = .checking
        manualCheckStatus = await performCheck()
    }

    // MARK: - Internals

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private func performCheck() async -> CheckStatus {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag = defaults.string(forKey: Key.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200:
                guard let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else {
                    log("unexpected response payload")
                    return .failed
                }
                defaults.set(now(), forKey: Key.lastCheckedAt)
                if let etag = http.value(forHTTPHeaderField: "ETag") {
                    defaults.set(etag, forKey: Key.etag)
                }
                defaults.set(release.tagName, forKey: Key.latestVersion)
                if let urlString = release.htmlURL {
                    defaults.set(urlString, forKey: Key.latestURL)
                }
                return publish(tag: release.tagName, urlString: release.htmlURL)
            case 304:
                // Not modified since the cached ETag — the persisted
                // latest release still holds.
                defaults.set(now(), forKey: Key.lastCheckedAt)
                return publish(
                    tag: defaults.string(forKey: Key.latestVersion) ?? "",
                    urlString: defaults.string(forKey: Key.latestURL)
                )
            default:
                log("HTTP \(http.statusCode)")
                return .failed
            }
        } catch {
            log(error.localizedDescription)
            return .failed
        }
    }

    private func publish(tag: String, urlString: String?) -> CheckStatus {
        let update = Self.update(fromTag: tag, urlString: urlString, current: currentVersion)
        availableUpdate = update
        return update.map { .updateAvailable($0) } ?? .upToDate
    }

    /// nil unless `tag` parses and is strictly newer than `current`.
    /// Malformed tags are treated as "no update", never as an error.
    static func update(fromTag tag: String, urlString: String?, current: String) -> AvailableUpdate? {
        guard let latest = UpdateSemVer(tag),
              let running = UpdateSemVer(current),
              latest > running else { return nil }
        let url = urlString.flatMap(URL.init(string:)) ?? fallbackReleasePage
        return AvailableUpdate(version: latest.display, url: url)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("harc: update check failed: \(message)\n".utf8))
    }
}
