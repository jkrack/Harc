import Foundation
import HarcDomain
import Testing
@testable import HarcUI

@MainActor
struct LibraryOriginDeviceLabelTests {
    @Test("Client origin label distinguishes local identity from unknown and named peers")
    func localAndRemoteOrigins() throws {
        let local = try DeviceID(Data(repeating: 1, count: 32))
        let peer = try DeviceID(Data(repeating: 2, count: 32))
        #expect(LibraryViewModel.originDeviceLabel(deviceID: local, localDeviceID: local, labels: [:]) == "This Mac")
        #expect(LibraryViewModel.originDeviceLabel(deviceID: peer, localDeviceID: local, labels: [:]) == "Another device")
        #expect(LibraryViewModel.originDeviceLabel(deviceID: peer, localDeviceID: local, labels: [peer: "  Meeting Mac  "]) == "Meeting Mac")
        #expect(LibraryViewModel.originDeviceLabel(deviceID: peer, localDeviceID: local, labels: [peer: "  "]) == "Another device")
        #expect(LibraryViewModel.originDeviceLabel(deviceID: local, localDeviceID: nil, labels: [:]) == "Another device")
        #expect(LibraryViewModel.originDeviceLabel(deviceID: local, localDeviceID: local, labels: [local: "Old label"]) == "This Mac")
    }
}
