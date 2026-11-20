import Darwin
import Foundation
import HarcDomain
import HarcTransfer
import Testing
@testable import HarcHost

@Suite("Host background audio resource admission")
struct HostCanonicalResourceAdmissionTests {
    private static let audioURL = URL(fileURLWithPath: "/fixture/audio.wav")
    private static let homeURL = URL(fileURLWithPath: "/fixture/home")
    private static let reserve = HostCanonicalResourceAdmission.reserveBytes

    private enum LookupFailure: Error { case unavailable }

    private static func residentMetadata() -> stat {
        var information = stat()
        information.st_mode = S_IFREG | S_IRUSR | S_IWUSR
        information.st_size = 46
        return information
    }

    @Test("missing, unknown and dataless metadata defer before capacity")
    func unavailableAudio() {
        var dataless = Self.residentMetadata()
        dataless.st_flags = UInt32(SF_DATALESS)
        for information in [nil, dataless] as [stat?] {
            var capacityQueries = 0
            #expect(throws: HostCanonicalResourceDeferred.audioNotResident) {
                try HostCanonicalResourceAdmission.requireResidentAudio(
                    at: Self.audioURL,
                    expectedByteCount: 46,
                    homeDirectory: Self.homeURL,
                    metadata: { _ in information },
                    availableBytes: { _ in
                        capacityQueries += 1
                        return .max
                    }
                )
            }
            #expect(capacityQueries == 0)
        }
        #expect(throws: HostCanonicalResourceDeferred.audioNotResident) {
            try HostCanonicalResourceAdmission.requireResidentAudio(
                at: Self.audioURL,
                expectedByteCount: 46,
                homeDirectory: Self.homeURL,
                metadata: { _ in throw LookupFailure.unavailable },
                availableBytes: { _ in .max }
            )
        }
    }

    @Test("unsafe existing metadata is terminal even when also marked dataless")
    func unsafeAudioIsNotAResourceDeferral() {
        var invalidLength = Self.residentMetadata()
        invalidLength.st_size = -1
        var symlink = Self.residentMetadata()
        symlink.st_mode = S_IFLNK | S_IRUSR
        var datalessSymlink = symlink
        datalessSymlink.st_flags = UInt32(SF_DATALESS)
        for information in [invalidLength, symlink, datalessSymlink] {
            var capacityQueries = 0
            #expect(throws: HarcHostError.unsafePublicationPath) {
                try HostCanonicalResourceAdmission.requireResidentAudio(
                    at: Self.audioURL,
                    expectedByteCount: 46,
                    homeDirectory: Self.homeURL,
                    metadata: { _ in information },
                    availableBytes: { _ in
                        capacityQueries += 1
                        return .max
                    }
                )
            }
            #expect(capacityQueries == 0)
        }
    }

    @Test("physical block counts are exact and unknown or overflowing values fail closed")
    func physicalCapacityArithmetic() throws {
        #expect(try HostCanonicalResourceAdmission.availableByteCount(
            blocks: 3, blockSize: 4_096
        ) == 12_288)
        #expect(try HostCanonicalResourceAdmission.availableByteCount(
            blocks: 0, blockSize: 4_096
        ) == 0)
        for (blocks, blockSize) in [
            (nil, UInt64(4_096)), (UInt64(1), nil), (UInt64(1), UInt64(0)),
            (UInt64.max, UInt64(2)),
        ] as [(UInt64?, UInt64?)] {
            #expect(throws: HostCanonicalResourceDeferred.capacityUnavailable) {
                try HostCanonicalResourceAdmission.availableByteCount(
                    blocks: blocks, blockSize: blockSize
                )
            }
        }
    }

    @Test("audio requires its full WAV allowance and home independently needs the reserve")
    func bothVolumesNeedSpace() throws {
        for blockedURL in [Self.audioURL, Self.homeURL] {
            #expect(throws: HostCanonicalResourceDeferred.insufficientCapacity) {
                try HostCanonicalResourceAdmission.requireResidentAudio(
                    at: Self.audioURL,
                    expectedByteCount: 46,
                    homeDirectory: Self.homeURL,
                    metadata: { _ in Self.residentMetadata() },
                    availableBytes: { url in
                        let required = Self.reserve + (url == Self.audioURL ? 46 : 0)
                        return url == blockedURL ? required - 1 : required
                    }
                )
            }
        }
        var queried: [URL] = []
        try HostCanonicalResourceAdmission.requireResidentAudio(
            at: Self.audioURL,
            expectedByteCount: 46,
            homeDirectory: Self.homeURL,
            metadata: { _ in Self.residentMetadata() },
            availableBytes: { url in
                queried.append(url)
                return Self.reserve + (url == Self.audioURL ? 46 : 0)
            }
        )
        #expect(queried == [Self.audioURL, Self.homeURL])
    }

    @Test("unknown capacity on either volume and reserve overflow defer")
    func unknownCapacityAndOverflow() {
        for unknownURL in [Self.audioURL, Self.homeURL] {
            #expect(throws: HostCanonicalResourceDeferred.capacityUnavailable) {
                try HostCanonicalResourceAdmission.requireCapacity(
                    at: Self.audioURL,
                    additionalBytes: 46,
                    homeDirectory: Self.homeURL,
                    availableBytes: { url in
                        if url == unknownURL { throw LookupFailure.unavailable }
                        return .max
                    }
                )
            }
        }
        var queried = false
        #expect(throws: HostCanonicalResourceDeferred.insufficientCapacity) {
            try HostCanonicalResourceAdmission.requireCapacity(
                at: Self.audioURL,
                additionalBytes: .max,
                homeDirectory: Self.homeURL,
                availableBytes: { _ in
                    queried = true
                    return .max
                }
            )
        }
        #expect(!queried)
    }

    @Test("injected checks preserve caller URL, byte counts and deferred errors")
    func checkInjection() {
        let admission = HostCanonicalResourceAdmission(
            checkResidentAudio: { url, bytes in
                #expect(url == Self.audioURL)
                #expect(bytes == 46)
                throw HostCanonicalResourceDeferred.audioNotResident
            },
            checkCapacity: { url, bytes in
                #expect(url == Self.homeURL)
                #expect(bytes == 47)
                throw HostCanonicalResourceDeferred.insufficientCapacity
            }
        )
        #expect(throws: HostCanonicalResourceDeferred.audioNotResident) {
            try admission.checkResidentAudio(Self.audioURL, 46)
        }
        #expect(throws: HostCanonicalResourceDeferred.insufficientCapacity) {
            try admission.checkCapacity(Self.homeURL, 47)
        }
    }

    @Test("default metadata and capacity checks fail closed for nonexistent fixture paths")
    func missingPaths() throws {
        let fixture = HostTestFixture()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.wav")
        #expect(throws: HostCanonicalResourceDeferred.audioNotResident) {
            try HostCanonicalResourceAdmission.requireResidentAudio(
                at: missing, expectedByteCount: 46
            )
        }
        #expect(throws: HostCanonicalResourceDeferred.capacityUnavailable) {
            try HostCanonicalResourceAdmission.requireCapacity(at: missing, additionalBytes: 46)
        }
    }

    @Test("adequate resources and resident metadata never authenticate WAV content")
    func admissionDoesNotAuthorizeContent() throws {
        let fixture = HostTestFixture()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try HostCanonicalPublicationPaths.make(
            root: root,
            captureStartedAt: fixture.beganAt,
            canonicalRecordingID: .random(),
            temporaryName: ".harc-fixture.partial"
        )
        // Exact expected length, but not a WAV. Admission must not bless it.
        try Data(repeating: 0, count: 46).write(to: paths.wavURL)
        try paths.requireResidentFile(at: paths.wavURL)
        try HostCanonicalResourceAdmission.requireResidentAudio(
            at: paths.wavURL,
            expectedByteCount: 46,
            homeDirectory: Self.homeURL,
            metadata: { url in
                var information = stat()
                guard lstat(url.path, &information) == 0 else { return nil }
                return information
            },
            availableBytes: { _ in .max }
        )
        #expect(throws: HarcHostError.invalidCanonicalWAV) {
            _ = try HostValidatedCanonicalArtifact(
                at: paths.wavURL, in: paths, totalFrames: 1,
                expectedPCMHash: CanonicalPCMHash(Data(repeating: 0, count: 32))
            )
        }
    }

    @Test("canonical metadata admission retains leaf and hierarchy safety")
    func canonicalPathSafety() throws {
        let fixture = HostTestFixture()
        let container = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("canonical", isDirectory: true)
        let paths = try HostCanonicalPublicationPaths.make(
            root: root, captureStartedAt: fixture.beganAt,
            canonicalRecordingID: .random(), temporaryName: ".harc-fixture.partial"
        )
        #expect(throws: HostCanonicalResourceDeferred.audioNotResident) {
            try paths.requireResidentFile(at: paths.wavURL)
        }
        let target = container.appendingPathComponent("target.wav")
        try Data([0, 1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.wavURL, withDestinationURL: target)
        #expect(throws: HarcHostError.unsafePublicationPath) {
            try paths.requireResidentFile(at: paths.wavURL)
        }
        try FileManager.default.removeItem(at: paths.wavURL)
        try FileManager.default.linkItem(at: target, to: paths.wavURL)
        #expect(throws: HarcHostError.unsafePublicationPath) {
            try paths.requireResidentFile(at: paths.wavURL)
        }
        try FileManager.default.removeItem(at: paths.wavURL)
        try Data([0, 1]).write(to: paths.wavURL)
        try #require(chmod(paths.wavURL.path, 0o622) == 0)
        #expect(throws: HarcHostError.unsafePublicationPath) {
            try paths.requireResidentFile(at: paths.wavURL)
        }
        try #require(chmod(paths.wavURL.path, 0o600) == 0)
        try paths.requireResidentFile(at: paths.wavURL)
        try FileManager.default.moveItem(at: root, to: container.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(throws: HarcHostError.unsafePublicationRoot) {
            try paths.requireResidentFile(at: paths.wavURL)
        }
    }

    @Test("staged admission validates generated names and leaves encoded hash proof mandatory")
    func stagedAdmission() async throws {
        let fixture = HostTestFixture()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await HarcHostStore.inMemory(stagingRoot: root, metadata: fixture.metadata)
        let descriptor = try fixture.descriptor(
            origin: OriginRecordingID(deviceID: fixture.deviceID, recordingUUID: UUID()),
            bytes: Data([0, 1])
        )
        let name = "\(UUID().uuidString.lowercased()).chunk"
        let staged = HostDurableStagedChunk(descriptor: descriptor, relativePath: "objects/\(name)")
        #expect(throws: HostCanonicalResourceDeferred.audioNotResident) {
            try store.requireResidentStagedObject(staged)
        }
        let url = root.appendingPathComponent("objects").appendingPathComponent(name)
        try Data([2, 3]).write(to: url)
        try store.requireResidentStagedObject(staged)
        let handle = try store.openDurableStagedObject(staged)
        defer { handle.close() }
        #expect(throws: HarcHostError.encodedHashMismatch) {
            try handle.verifyEncodedObject(matches: descriptor, maximumFragmentBytes: 1)
        }
        #expect(throws: HarcHostError.unsafeStagingPath) {
            try store.requireResidentStagedObject(HostDurableStagedChunk(
                descriptor: descriptor, relativePath: "objects/../\(name)"
            ))
        }
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("target.chunk")
        try Data([0, 1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: HarcHostError.unsafeStagingPath) {
            try store.requireResidentStagedObject(staged)
        }
    }
}
