import Foundation
import Testing
import HarcDomain
import HarcStore
@testable import HarcUI

@Suite("Library origin labels")
@MainActor
struct LibraryOriginLabelTests {
    @Test("exact local identity is This Mac without any paired-device labels")
    func localIdentity() async throws {
        let library = LibraryViewModel(store: try await RecordingStore.inMemory())
        let local = try device(1)
        library.localOriginDeviceID = local
        #expect(library.originDeviceLabel(for: local) == "This Mac")
        #expect(library.originLabel(for: recording(local)) == "Recorded on this Mac")
        #expect(library.originDeviceLabel(for: try device(2)) == "Unknown device")
    }

    @Test("local identity wins over a stale registry label; remote labels are preserved")
    func loadedLabels() async throws {
        let library = LibraryViewModel(store: try await RecordingStore.inMemory())
        let local = try device(1)
        let remote = try device(2)
        library.localOriginDeviceID = local
        library.loadOriginDeviceLabels = { [local: "Old computer name", remote: "  James’s iPhone \n"] }
        await library.refreshOriginDeviceLabels()
        #expect(library.originDeviceLabel(for: local) == "This Mac")
        #expect(library.originDeviceLabel(for: remote) == "James’s iPhone")
        #expect(library.originLabel(for: recording(remote)) == "Recorded on James’s iPhone")
    }

    @Test("unresolved and empty labels do not imply a different device")
    func unresolvedLabels() async throws {
        let library = LibraryViewModel(store: try await RecordingStore.inMemory())
        let unknown = try device(1)
        let blank = try device(2)
        library.loadOriginDeviceLabels = { [blank: " \n"] }
        await library.refreshOriginDeviceLabels()
        for id in [unknown, blank] {
            #expect(library.originDeviceLabel(for: id) == "Unknown device")
            #expect(library.originLabel(for: recording(id)) == "Recording device unknown")
        }
        #expect(library.originLabel(for: Recording(wavPath: "/synthetic/no-origin.wav", startedAt: Date())) == "Device not recorded")
    }

    @Test("failed remote lookup keeps exact self identity and previously known remote names")
    func failedLookup() async throws {
        let library = LibraryViewModel(store: try await RecordingStore.inMemory())
        let local = try device(1)
        let remote = try device(2)
        library.localOriginDeviceID = local
        library.loadOriginDeviceLabels = { [remote: "Paired Mac"] }
        await library.refreshOriginDeviceLabels()
        library.loadOriginDeviceLabels = { throw LookupError.unavailable }
        await library.refreshOriginDeviceLabels()
        #expect(library.originDeviceLabel(for: local) == "This Mac")
        #expect(library.originDeviceLabel(for: remote) == "Paired Mac")
        #expect(library.originDeviceLabel(for: try device(3)) == "Unknown device")
    }

    private enum LookupError: Error { case unavailable }
    private func device(_ value: UInt8) throws -> DeviceID {
        try DeviceID(Data(repeating: value, count: 32))
    }
    private func recording(_ deviceID: DeviceID) -> Recording {
        Recording(
            wavPath: "/synthetic/origin.wav", startedAt: Date(),
            originID: OriginRecordingID(deviceID: deviceID, recordingUUID: UUID())
        )
    }
}
