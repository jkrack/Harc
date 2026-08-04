import Foundation
import Testing
@testable import HarcAudio

@Suite("Audio input device selection")
struct AudioInputDeviceCatalogTests {
    private let builtIn = AudioInputDevice(
        deviceID: 11,
        uid: "builtin-uid",
        name: "MacBook Pro Microphone",
        isSystemDefault: true
    )
    private let rode = AudioInputDevice(
        deviceID: 42,
        uid: "rode-uid",
        name: "RØDE NT-USB",
        isSystemDefault: false
    )

    @Test("system default resolves the current default device")
    func resolvesSystemDefault() {
        let resolved = AudioInputDeviceCatalog.resolvedDevice(
            for: .systemDefault,
            devices: [builtIn, rode],
            defaultDeviceID: builtIn.deviceID
        )

        #expect(resolved == builtIn)
    }

    @Test("explicit UID wins over the system default")
    func resolvesExplicitUID() {
        let resolved = AudioInputDeviceCatalog.resolvedDevice(
            for: MicrophoneSelection(device: rode),
            devices: [builtIn, rode],
            defaultDeviceID: builtIn.deviceID
        )

        #expect(resolved == rode)
    }

    @Test("disconnected explicit device never silently falls back")
    func explicitSelectionDoesNotFallback() {
        let disconnected = MicrophoneSelection(
            deviceUID: "dock-uid",
            lastKnownName: "Docking Station Audio"
        )
        let resolved = AudioInputDeviceCatalog.resolvedDevice(
            for: disconnected,
            devices: [builtIn, rode],
            defaultDeviceID: builtIn.deviceID
        )

        #expect(resolved == nil)
        #expect(disconnected.lastKnownName == "Docking Station Audio")
    }

    @Test("selection persistence retains stable UID and display name")
    func selectionRoundTrip() throws {
        let selection = MicrophoneSelection(device: rode)
        let encoded = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(MicrophoneSelection.self, from: encoded)

        #expect(decoded == selection)
        #expect(decoded.deviceUID == "rode-uid")
    }

    @Test("live Core Audio enumeration never returns duplicate stable UIDs")
    func liveEnumerationHasUniqueUIDs() {
        let devices = AudioInputDeviceCatalog.availableDevices()
        #expect(Set(devices.map(\.uid)).count == devices.count)
    }
}
