import Testing
import Foundation
@testable import HarcUI

// MARK: - Stubs

/// Thread-safe call counter usable from a @Sendable fetch stub.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Mutable clock box injected as the checker's `now`.
private final class StubClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.now = now }
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 60 * 60) }
}

/// Captures the last request seen by the fetch stub.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func record(_ r: URLRequest) {
        lock.lock()
        request = r
        lock.unlock()
    }

    var last: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private func isolatedDefaults() -> UserDefaults {
    let name = "UpdateCheckerTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func releaseFetch(
    tag: String,
    counter: CallCounter? = nil,
    recorder: RequestRecorder? = nil,
    status: Int = 200,
    etag: String? = "\"etag-1\""
) -> UpdateChecker.Fetch {
    { request in
        counter?.increment()
        recorder?.record(request)
        let json = """
        {"tag_name": "\(tag)", "html_url": "https://github.com/jkrack/Harc/releases/tag/\(tag)"}
        """
        var headers: [String: String] = [:]
        if let etag { headers["ETag"] = etag }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (Data(json.utf8), response)
    }
}

@MainActor
private func makeChecker(
    current: String,
    fetch: @escaping UpdateChecker.Fetch,
    clock: StubClock = StubClock(),
    defaults: UserDefaults = isolatedDefaults(),
    enabled: Bool = true
) -> UpdateChecker {
    UpdateChecker(
        currentVersion: current,
        fetch: fetch,
        now: { clock.now },
        defaults: defaults,
        updatesEnabled: { enabled }
    )
}

// MARK: - Semver parsing + comparison

struct UpdateSemVerTests {
    @Test("parses plain and v-prefixed tags")
    func parsesTags() {
        let a = UpdateSemVer("v1.2.3")
        #expect(a?.major == 1)
        #expect(a?.minor == 2)
        #expect(a?.patch == 3)
        #expect(UpdateSemVer("0.4.1") != nil)
    }

    @Test("missing components pad to zero")
    func padsMissingComponents() {
        #expect(UpdateSemVer("1.2") == UpdateSemVer("1.2.0"))
        #expect(UpdateSemVer("2") == UpdateSemVer("2.0.0"))
    }

    @Test("prerelease and build suffixes are dropped")
    func dropsSuffixes() {
        #expect(UpdateSemVer("v1.2.3-beta.1") == UpdateSemVer("1.2.3"))
        #expect(UpdateSemVer("1.2.3+build7") == UpdateSemVer("1.2.3"))
    }

    @Test("malformed tags parse to nil")
    func malformedTagsAreNil() {
        #expect(UpdateSemVer("") == nil)
        #expect(UpdateSemVer("banana") == nil)
        #expect(UpdateSemVer("1.2.x") == nil)
        #expect(UpdateSemVer("1..3") == nil)
        #expect(UpdateSemVer("1.2.3.4") == nil)
        #expect(UpdateSemVer("v") == nil)
    }

    @Test("numeric comparison, not lexicographic: 0.10.0 > 0.9.9")
    func numericComparison() {
        #expect(UpdateSemVer("0.10.0")! > UpdateSemVer("0.9.9")!)
        #expect(UpdateSemVer("1.0.0")! > UpdateSemVer("0.99.99")!)
        #expect(UpdateSemVer("0.4.1")! == UpdateSemVer("v0.4.1")!)
        #expect(UpdateSemVer("0.4.1")! < UpdateSemVer("0.4.2")!)
    }
}

// MARK: - UpdateChecker behavior

@MainActor
struct UpdateCheckerTests {
    @Test("equal versions report up to date and publish no update")
    func equalVersionsUpToDate() async {
        let checker = makeChecker(current: "0.4.1", fetch: releaseFetch(tag: "v0.4.1"))
        await checker.checkNow()
        #expect(checker.manualCheckStatus == .upToDate)
        #expect(checker.availableUpdate == nil)
    }

    @Test("newer tag publishes an available update with normalized version")
    func newerTagPublishesUpdate() async {
        let checker = makeChecker(current: "0.9.9", fetch: releaseFetch(tag: "v0.10.0"))
        await checker.checkNow()
        #expect(checker.availableUpdate?.version == "0.10.0")
        #expect(checker.availableUpdate?.url.absoluteString
            == "https://github.com/jkrack/Harc/releases/tag/v0.10.0")
        #expect(checker.manualCheckStatus == .updateAvailable(checker.availableUpdate!))
    }

    @Test("older tag than the running build publishes no update")
    func olderTagNoUpdate() async {
        let checker = makeChecker(current: "0.5.0", fetch: releaseFetch(tag: "v0.4.9"))
        await checker.checkNow()
        #expect(checker.manualCheckStatus == .upToDate)
        #expect(checker.availableUpdate == nil)
    }

    @Test("malformed tag is treated as no update, not a failure")
    func malformedTagIsNoUpdate() async {
        let checker = makeChecker(current: "0.4.1", fetch: releaseFetch(tag: "banana"))
        await checker.checkNow()
        #expect(checker.manualCheckStatus == .upToDate)
        #expect(checker.availableUpdate == nil)
    }

    @Test("scheduled checks are throttled to once per day")
    func dailyThrottle() async {
        let counter = CallCounter()
        let clock = StubClock()
        let checker = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.4.1", counter: counter),
            clock: clock
        )
        await checker.checkIfDue()
        #expect(counter.count == 1)

        // Same day — no second request.
        clock.advance(hours: 1)
        await checker.checkIfDue()
        #expect(counter.count == 1)

        // Still inside 24h.
        clock.advance(hours: 22)
        await checker.checkIfDue()
        #expect(counter.count == 1)

        // Past 24h since the first check — fires again.
        clock.advance(hours: 2)
        await checker.checkIfDue()
        #expect(counter.count == 2)
    }

    @Test("throttle persists across checker instances via UserDefaults")
    func throttlePersistsAcrossInstances() async {
        let counter = CallCounter()
        let clock = StubClock()
        let defaults = isolatedDefaults()
        let fetch = releaseFetch(tag: "v0.4.1", counter: counter)

        let first = makeChecker(current: "0.4.1", fetch: fetch, clock: clock, defaults: defaults)
        await first.checkIfDue()
        #expect(counter.count == 1)

        // "Relaunch" one hour later — still throttled.
        clock.advance(hours: 1)
        let second = makeChecker(current: "0.4.1", fetch: fetch, clock: clock, defaults: defaults)
        await second.checkIfDue()
        #expect(counter.count == 1)
    }

    @Test("disabled pref makes no request on the scheduled path")
    func disabledPrefNoRequest() async {
        let counter = CallCounter()
        let checker = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.5.0", counter: counter),
            enabled: false
        )
        await checker.checkIfDue()
        #expect(counter.count == 0)
        #expect(checker.availableUpdate == nil)
    }

    @Test("manual check bypasses the throttle and the pref")
    func manualCheckBypasses() async {
        let counter = CallCounter()
        let clock = StubClock()
        let checker = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.4.1", counter: counter),
            clock: clock,
            enabled: false
        )
        // Scheduled path is off.
        await checker.checkIfDue()
        #expect(counter.count == 0)

        // Manual fires anyway.
        await checker.checkNow()
        #expect(counter.count == 1)

        // And again immediately — no throttle.
        await checker.checkNow()
        #expect(counter.count == 2)
    }

    @Test("second request sends the cached ETag; 304 keeps the known update")
    func etagRoundTrip() async {
        let recorder = RequestRecorder()
        let defaults = isolatedDefaults()
        let clock = StubClock()

        let first = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.5.0", recorder: recorder, etag: "\"tag-a\""),
            clock: clock,
            defaults: defaults
        )
        await first.checkNow()
        #expect(recorder.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(first.availableUpdate?.version == "0.5.0")

        // Next check: ETag goes out, server says 304, cached update holds.
        let notModified: UpdateChecker.Fetch = { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 304, httpVersion: nil, headerFields: [:]
            )!
            return (Data(), response)
        }
        let second = makeChecker(current: "0.4.1", fetch: notModified, clock: clock, defaults: defaults)
        await second.checkNow()
        #expect(recorder.last?.value(forHTTPHeaderField: "If-None-Match") == "\"tag-a\"")
        #expect(second.manualCheckStatus == .updateAvailable(second.availableUpdate!))
        #expect(second.availableUpdate?.version == "0.5.0")
    }

    @Test("network failure is silent: failed status, no update, no throw")
    func networkFailureIsSilent() async {
        struct Offline: Error {}
        let checker = makeChecker(current: "0.4.1", fetch: { _ in throw Offline() })
        await checker.checkNow()
        #expect(checker.manualCheckStatus == .failed)
        #expect(checker.availableUpdate == nil)
    }

    @Test("non-200 status is a silent failure and does not stamp the throttle")
    func serverErrorDoesNotStampThrottle() async {
        let counter = CallCounter()
        let clock = StubClock()
        let checker = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.5.0", counter: counter, status: 500),
            clock: clock
        )
        await checker.checkIfDue()
        #expect(counter.count == 1)
        #expect(checker.availableUpdate == nil)

        // A failed attempt shouldn't block the next scheduled retry.
        clock.advance(hours: 1)
        await checker.checkIfDue()
        #expect(counter.count == 2)
    }

    @Test("cached update surfaces on init without a network request")
    func cachedUpdateSurfacesOnInit() async {
        let defaults = isolatedDefaults()
        let counter = CallCounter()
        let seed = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.6.0"),
            defaults: defaults
        )
        await seed.checkNow()
        #expect(seed.availableUpdate?.version == "0.6.0")

        // Fresh instance (relaunch): update known immediately, zero requests.
        let relaunched = makeChecker(
            current: "0.4.1",
            fetch: releaseFetch(tag: "v0.6.0", counter: counter),
            defaults: defaults
        )
        #expect(relaunched.availableUpdate?.version == "0.6.0")
        #expect(counter.count == 0)

        // After upgrading past the cached release, the row clears.
        let upgraded = makeChecker(
            current: "0.6.0",
            fetch: releaseFetch(tag: "v0.6.0", counter: counter),
            defaults: defaults
        )
        #expect(upgraded.availableUpdate == nil)
    }

    @Test("updateChecksEnabled pref defaults to true and persists")
    func updateChecksEnabledPrefPersists() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "harc.updateChecksEnabled")

        let prefs = HarcPreferences()
        #expect(prefs.updateChecksEnabled == true)

        prefs.updateChecksEnabled = false
        #expect(HarcPreferences().updateChecksEnabled == false)

        // Restore default for subsequent tests.
        defaults.removeObject(forKey: "harc.updateChecksEnabled")
    }
}
