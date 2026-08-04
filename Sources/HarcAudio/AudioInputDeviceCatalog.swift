import Foundation
import CoreAudio

/// A stable, user-facing description of a Core Audio input device.
///
/// `deviceID` is valid only for the current hardware session. Preferences use
/// `uid`, which survives restarts and ordinary dock disconnect/reconnect cycles.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
    public let deviceID: UInt32
    public let uid: String
    public let name: String
    public let isSystemDefault: Bool

    public var id: String { uid }

    public init(deviceID: UInt32, uid: String, name: String, isSystemDefault: Bool) {
        self.deviceID = deviceID
        self.uid = uid
        self.name = name
        self.isSystemDefault = isSystemDefault
    }
}

/// The microphone route Harc should resolve immediately before opening audio.
///
/// `lastKnownName` keeps an unplugged explicit selection understandable in the
/// UI. Harc never silently substitutes a different device for an explicit UID.
public struct MicrophoneSelection: Codable, Equatable, Sendable {
    public let deviceUID: String?
    public let lastKnownName: String?

    public static let systemDefault = MicrophoneSelection(
        deviceUID: nil,
        lastKnownName: nil
    )

    public var usesSystemDefault: Bool { deviceUID == nil }

    public init(deviceUID: String?, lastKnownName: String?) {
        self.deviceUID = deviceUID
        self.lastKnownName = lastKnownName
    }

    public init(device: AudioInputDevice) {
        self.init(deviceUID: device.uid, lastKnownName: device.name)
    }
}

/// Core Audio input enumeration and stable-UID resolution.
public enum AudioInputDeviceCatalog {
    public static func availableDevices() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()
        let ids = objectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return ids.compactMap { id in
            guard hasInputStreams(deviceID: id),
                  isAlive(deviceID: id),
                  let uid = stringProperty(
                    objectID: id,
                    selector: kAudioDevicePropertyDeviceUID,
                    scope: kAudioObjectPropertyScopeGlobal
                  ),
                  let name = stringProperty(
                    objectID: id,
                    selector: kAudioObjectPropertyName,
                    scope: kAudioObjectPropertyScopeGlobal
                  ) else {
                return nil
            }
            return AudioInputDevice(
                deviceID: id,
                uid: uid,
                name: name,
                isSystemDefault: id == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSystemDefault != rhs.isSystemDefault {
                return lhs.isSystemDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func resolvedDevice(
        for selection: MicrophoneSelection,
        devices: [AudioInputDevice]? = nil
    ) -> AudioInputDevice? {
        let candidates = devices ?? availableDevices()
        return resolvedDevice(
            for: selection,
            devices: candidates,
            defaultDeviceID: defaultInputDeviceID()
        )
    }

    /// Pure resolver used by tests and by the live catalog wrapper.
    static func resolvedDevice(
        for selection: MicrophoneSelection,
        devices: [AudioInputDevice],
        defaultDeviceID: UInt32?
    ) -> AudioInputDevice? {
        if let uid = selection.deviceUID {
            return devices.first { $0.uid == uid }
        }
        guard let defaultDeviceID else { return nil }
        return devices.first { $0.deviceID == defaultDeviceID }
    }

    public static func defaultInputDeviceID() -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func hasInputStreams(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func isAlive(deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &alive
        )
        return status == noErr && alive != 0
    }

    private static func objectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }
        var values = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        return status == noErr ? values : []
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
