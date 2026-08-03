import CryptoKit
import Foundation
@testable import HarcHost
import HarcDomain
import HarcIdentity
import HarcTransfer

struct HostTestFixture {
    let hostKey = SoftwareP256SigningKey()
    let deviceKey = SoftwareP256SigningKey()
    let libraryID = LibraryID.random()
    let hostStateID = HostStateID.random()
    let beganAt = Date(timeIntervalSince1970: 1_800_000_000)

    var metadata: HarcHostMetadata {
        HarcHostMetadata(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            hostStateID: hostStateID
        )
    }

    var deviceID: DeviceID { deviceKey.publicKey.deviceID }

    func grant(
        id: GrantID = .random(),
        epoch: GrantEpoch = .initial,
        scopes: Set<AuthorizationScope> = [.recordingUploadOwn, .recordingReadOwn],
        expiresAt: Date? = nil
    ) throws -> DeviceGrantClaims {
        try DeviceGrantClaims(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            grantID: id,
            devicePublicKey: deviceKey.publicKey,
            scopes: scopes,
            grantEpoch: epoch,
            issuedAt: beganAt,
            expiresAt: expiresAt,
            minimumCompatibleProtocolMinor: 0,
            maximumCompatibleProtocolMinor: 0
        )
    }

    func context(for grant: DeviceGrantClaims) -> AuthenticatedDeviceContext {
        AuthenticatedDeviceContext(
            libraryID: libraryID,
            hostAuthorityID: hostKey.publicKey.hostAuthorityID,
            authenticatedDeviceID: deviceID,
            grantID: grant.grantID,
            grantEpoch: grant.grantEpoch
        )
    }

    func temporaryDirectory(_ suffix: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarcHostTests-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func profile() throws -> FrozenUploadProfile {
        try FrozenUploadProfile(
            protocolVersion: TransferProtocolVersion(minor: 0),
            encoding: .rawPCMFixture,
            requiredCapabilities: [],
            negotiatedCapabilitiesSHA256: NegotiatedCapabilitiesSHA256(Data(repeating: 0x31, count: 32)),
            profileSHA256: UploadProfileSHA256(Data(repeating: 0x32, count: 32)),
            purpose: .fixtureLoopback
        )
    }

    func descriptor(
        origin: OriginRecordingID,
        chunkIndex: UInt32 = 0,
        startFrame: UInt64 = 0,
        bytes: Data
    ) throws -> LogicalChunkDescriptor {
        precondition(bytes.count.isMultiple(of: 2))
        let digest = Data(SHA256.hash(data: bytes))
        return try LogicalChunkDescriptor(
            originRecordingID: origin,
            chunkID: .random(),
            chunkIndex: chunkIndex,
            canonicalStartFrame: startFrame,
            canonicalFrameCount: UInt64(bytes.count / 2),
            encoding: .rawPCMFixture,
            encodedByteLength: UInt64(bytes.count),
            encodedSHA256: EncodedChunkSHA256(digest),
            canonicalDecodedByteLength: UInt64(bytes.count),
            canonicalDecodedSHA256: CanonicalPCMHash(digest)
        )
    }
}

struct FixedHostVolumeCapacityProvider: HostVolumeCapacityProvider {
    let available: UInt64
    let total: UInt64

    init(available: UInt64 = 1_000_000_000_000, total: UInt64 = 1_000_000_000_000) {
        self.available = available
        self.total = total
    }

    func capacity(for stagingRoot: URL) throws -> HostVolumeCapacity {
        HostVolumeCapacity(availableBytes: available, totalBytes: total)
    }
}

enum InjectedHostCrash: Error, Equatable {
    case security(SecurityRegistryFailurePoint)
    case staging(StagingFailurePoint)
}

final class LockedHostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

actor OneShotSecurityFailureInjector: SecurityRegistryFailureInjector {
    private var target: SecurityRegistryFailurePoint?

    init(_ target: SecurityRegistryFailurePoint?) { self.target = target }

    func hit(_ point: SecurityRegistryFailurePoint) throws {
        guard target == point else { return }
        target = nil
        throw InjectedHostCrash.security(point)
    }
}

actor OneShotStagingFailureInjector: StagingFailureInjector {
    private var target: StagingFailurePoint?

    init(_ target: StagingFailurePoint?) { self.target = target }

    func hit(_ point: StagingFailurePoint) throws {
        guard target == point else { return }
        target = nil
        throw InjectedHostCrash.staging(point)
    }
}

/// Models successive process deaths in one deterministic test without making
/// unrelated staging checkpoints consume the next scheduled failure.
actor SequencedStagingFailureInjector: StagingFailureInjector {
    private var targets: [StagingFailurePoint]

    init(_ targets: [StagingFailurePoint]) {
        self.targets = targets
    }

    func hit(_ point: StagingFailurePoint) throws {
        guard targets.first == point else { return }
        targets.removeFirst()
        throw InjectedHostCrash.staging(point)
    }
}

actor SuspendingStagingFailureInjector: StagingFailureInjector {
    private var target: StagingFailurePoint?
    private var armed: Bool
    private var reachedTarget = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(_ target: StagingFailurePoint, initiallyArmed: Bool = true) {
        self.target = target
        armed = initiallyArmed
    }

    func arm() {
        armed = true
    }

    func hit(_ point: StagingFailurePoint) async {
        guard armed, target == point else { return }
        armed = false
        target = nil
        reachedTarget = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilSuspended() async {
        if reachedTarget { return }
        await withCheckedContinuation { continuation in
            reachedWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

struct ClockAdvancingStagingInjector: StagingFailureInjector {
    let point: StagingFailurePoint
    let clock: LockedHostClock
    let advancedTime: Date

    func hit(_ visitedPoint: StagingFailurePoint) {
        if visitedPoint == point {
            clock.set(advancedTime)
        }
    }
}

struct ClockAdvancingCrashStagingInjector: StagingFailureInjector {
    let point: StagingFailurePoint
    let clock: LockedHostClock
    let advancedTime: Date

    func hit(_ visitedPoint: StagingFailurePoint) throws {
        guard visitedPoint == point else { return }
        clock.set(advancedTime)
        throw InjectedHostCrash.staging(point)
    }
}
