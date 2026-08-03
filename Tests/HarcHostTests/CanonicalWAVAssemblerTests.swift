import CryptoKit
import Foundation
import HarcDomain
import HarcTransfer
import Testing
@testable import HarcHost

private actor CanonicalByteCollector {
    private var value = Data()
    func append(_ bytes: Data) { value.append(bytes) }
    func data() -> Data { value }
}

@Suite("Host canonical WAV publication primitives")
struct CanonicalWAVAssemblerTests {
    @Test("one upload cannot enter two publication sagas concurrently")
    func publicationActivityGateRejectsDuplicateClaim() throws {
        let uploadID = UploadID.random()
        var gate = HostPublicationActivityGate()

        try gate.claim(uploadID)
        #expect(throws: HarcHostError.canonicalPublicationAlreadyInProgress(uploadID)) {
            try gate.claim(uploadID)
        }

        gate.release(uploadID)
        try gate.claim(uploadID)
        gate.release(uploadID)
    }

    @Test("fixture decoder streams only explicit loopback raw PCM")
    func fixtureDecoderIsFailClosed() async throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0 ..< 32_000).map { UInt8(truncatingIfNeeded: $0) })
        let stagingDirectory = try HostStagingDirectory(root: directory)
        let objectName = "\(UUID().uuidString.lowercased()).chunk"
        let source = directory
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(objectName)
        try bytes.write(to: source)
        let origin = OriginRecordingID(
            deviceID: fixture.deviceID,
            recordingUUID: UUID()
        )
        let descriptor = try fixture.descriptor(origin: origin, bytes: bytes)
        let collector = CanonicalByteCollector()
        let fixtureHandle = try HostStagedObjectReadHandle(
            directory: stagingDirectory,
            objectName: objectName
        )
        defer { fixtureHandle.close() }
        let request = HostChunkDecodeRequest(
            stagedEncodedHandle: fixtureHandle,
            descriptor: descriptor,
            uploadPurpose: .fixtureLoopback
        )
        try await RawPCMFixtureHostChunkDecoder().decode(request) { fragment in
            await collector.append(fragment)
        }
        #expect(await collector.data() == bytes)

        let productionHandle = try HostStagedObjectReadHandle(
            directory: stagingDirectory,
            objectName: objectName
        )
        defer { productionHandle.close() }
        let productionRequest = HostChunkDecodeRequest(
            stagedEncodedHandle: productionHandle,
            descriptor: descriptor,
            uploadPurpose: .production
        )
        await #expect(throws: HarcHostError.fixtureDecoderForbidden) {
            try await RawPCMFixtureHostChunkDecoder().decode(productionRequest) { _ in }
        }
        await #expect(throws: HarcHostError.qualifiedDecoderUnavailable(
            codec: descriptor.encoding.codec.rawValue,
            container: descriptor.encoding.container.rawValue
        )) {
            try await QualifiedHostChunkDecoderUnavailable().decode(request) { _ in }
        }
    }

    @Test("canonical WAV is exact, synchronized, exclusively published, and hash validated")
    func exactWAVPublication() throws {
        let fixture = HostTestFixture()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pcm = Data((0 ..< 64_000).map { UInt8(truncatingIfNeeded: $0) })
        let hash = try CanonicalPCMHash(Data(SHA256.hash(data: pcm)))
        let paths = try HostCanonicalPublicationPaths.make(
            root: root,
            captureStartedAt: fixture.beganAt,
            canonicalRecordingID: .random(),
            temporaryName: ".harc-\(UUID().uuidString.lowercased()).partial"
        )
        let writer = try HostCanonicalWAVAssembler(
            paths: paths,
            totalFrames: UInt64(pcm.count / 2)
        )
        try writer.appendCanonicalPCM(pcm.prefix(31_337))
        try writer.appendCanonicalPCM(pcm.dropFirst(31_337))
        _ = try writer.synchronizeAndClose(expectedPCMHash: hash)
        try HostCanonicalWAVAssembler.publishExclusively(in: paths)
        try HostCanonicalWAVAssembler.synchronizeDirectory(paths)
        try HostCanonicalWAVAssembler.validatePublishedFile(
            at: paths.wavURL,
            in: paths,
            totalFrames: UInt64(pcm.count / 2),
            expectedPCMHash: hash
        )

        let file = try Data(contentsOf: paths.wavURL)
        #expect(file.count == pcm.count + 44)
        #expect(file.prefix(4) == Data("RIFF".utf8))
        #expect(file[8 ..< 12] == Data("WAVE".utf8))
        #expect(file.suffix(pcm.count) == pcm)
    }

    @Test("classic RIFF limit is enforced without allocating the declared body")
    func classicRIFFCeiling() throws {
        let maximumFrames = HostCanonicalWAVLayout.maximumPCMByteCount / 2
        _ = try HostCanonicalWAVLayout(totalFrames: maximumFrames)
        #expect(throws: HarcHostError.classicRIFFSizeExceeded(
            maximumPCMBytes: HostCanonicalWAVLayout.maximumPCMByteCount,
            requestedPCMBytes: (maximumFrames + 1) * 2
        )) {
            _ = try HostCanonicalWAVLayout(totalFrames: maximumFrames + 1)
        }
    }

    @Test("exclusive publication and provenance sidecars never overwrite conflicts")
    func conflictsNeverOverwrite() throws {
        let fixture = HostTestFixture()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try HostCanonicalPublicationPaths.make(
            root: root,
            captureStartedAt: fixture.beganAt,
            canonicalRecordingID: .random(),
            temporaryName: ".harc-\(UUID().uuidString.lowercased()).partial"
        )
        try Data("existing".utf8).write(to: paths.wavURL)
        try Data("candidate".utf8).write(to: paths.temporaryURL)
        #expect(throws: HarcHostError.canonicalDestinationExists) {
            try HostCanonicalWAVAssembler.publishExclusively(in: paths)
        }
        #expect(try Data(contentsOf: paths.wavURL) == Data("existing".utf8))

        let manifest = Data("manifest-a".utf8)
        let staleTemporary = paths.directory.appendingPathComponent(
            ".harc-\(paths.manifestSidecarURL.lastPathComponent).partial"
        )
        try Data("partial-before-crash".utf8).write(to: staleTemporary)
        try HostCanonicalWAVAssembler.writeExactSidecar(
            manifest,
            to: paths.manifestSidecarURL,
            in: paths
        )
        #expect(!FileManager.default.fileExists(atPath: staleTemporary.path))
        try HostCanonicalWAVAssembler.writeExactSidecar(
            manifest,
            to: paths.manifestSidecarURL,
            in: paths
        )
        #expect(throws: HarcHostError.provenanceSidecarConflict) {
            try HostCanonicalWAVAssembler.writeExactSidecar(
                Data("manifest-b".utf8),
                to: paths.manifestSidecarURL,
                in: paths
            )
        }
        #expect(try Data(contentsOf: paths.manifestSidecarURL) == manifest)
    }

    @Test("host paths reject client-like names and symlinked publication roots")
    func unsafePathsFailClosed() throws {
        let fixture = HostTestFixture()
        let directory = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: HarcHostError.unsafePublicationPath) {
            _ = try HostCanonicalPublicationPaths.make(
                root: directory,
                captureStartedAt: fixture.beganAt,
                canonicalRecordingID: .random(),
                temporaryName: "../../client.wav"
            )
        }

        let real = directory.appendingPathComponent("real", isDirectory: true)
        let linked = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        #expect(throws: HarcHostError.unsafePublicationRoot) {
            _ = try HostCanonicalPublicationPaths.make(
                root: linked,
                captureStartedAt: fixture.beganAt,
                canonicalRecordingID: .random(),
                temporaryName: ".harc-test.partial"
            )
        }

        let realParent = directory.appendingPathComponent("real-parent", isDirectory: true)
        let linkedParent = directory.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: realParent
        )
        #expect(throws: HarcHostError.unsafePublicationRoot) {
            _ = try HostCanonicalPublicationPaths.make(
                root: linkedParent.appendingPathComponent("canonical", isDirectory: true),
                captureStartedAt: fixture.beganAt,
                canonicalRecordingID: .random(),
                temporaryName: ".harc-test.partial"
            )
        }
    }

    @Test("retained directory descriptors reject a replaced canonical-root ancestor")
    func replacedAncestorFailsClosed() throws {
        let fixture = HostTestFixture()
        let container = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let canonicalRoot = container.appendingPathComponent("canonical", isDirectory: true)
        let attackerRoot = container.appendingPathComponent("attacker", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: attackerRoot, withIntermediateDirectories: false)

        let paths = try HostCanonicalPublicationPaths.make(
            root: canonicalRoot,
            captureStartedAt: fixture.beganAt,
            canonicalRecordingID: .random(),
            temporaryName: ".harc-ancestor-test.partial"
        )

        let retainedRoot = container.appendingPathComponent("retained", isDirectory: true)
        try FileManager.default.moveItem(at: canonicalRoot, to: retainedRoot)
        try FileManager.default.createSymbolicLink(
            at: canonicalRoot,
            withDestinationURL: attackerRoot
        )

        #expect(throws: HarcHostError.unsafePublicationRoot) {
            _ = try HostCanonicalWAVAssembler(paths: paths, totalFrames: 1)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: attackerRoot.path).isEmpty)
    }

    @Test("symlinked final artifacts are rejected without following or modifying their targets")
    func symlinkedArtifactsFailClosed() throws {
        let fixture = HostTestFixture()
        let root = try fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try HostCanonicalPublicationPaths.make(
            root: root,
            captureStartedAt: fixture.beganAt,
            canonicalRecordingID: .random(),
            temporaryName: ".harc-symlink-test.partial"
        )
        let victim = root.appendingPathComponent("victim")
        let victimBytes = Data("must-survive".utf8)
        try victimBytes.write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: paths.wavURL,
            withDestinationURL: victim
        )

        let hash = try CanonicalPCMHash(Data(SHA256.hash(data: Data([0, 0]))))
        #expect(throws: HarcHostError.unsafePublicationPath) {
            try HostCanonicalWAVAssembler.validatePublishedFile(
                at: paths.wavURL,
                in: paths,
                totalFrames: 1,
                expectedPCMHash: hash
            )
        }

        let sidecarTemporary = paths.directory.appendingPathComponent(
            ".harc-\(paths.manifestSidecarURL.lastPathComponent).partial"
        )
        try FileManager.default.createSymbolicLink(
            at: sidecarTemporary,
            withDestinationURL: victim
        )
        #expect(throws: HarcHostError.unsafePublicationPath) {
            try HostCanonicalWAVAssembler.writeExactSidecar(
                Data("manifest".utf8),
                to: paths.manifestSidecarURL,
                in: paths
            )
        }
        #expect(try Data(contentsOf: victim) == victimBytes)
    }
}
