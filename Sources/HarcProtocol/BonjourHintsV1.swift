import Foundation

/// Strict, nonsecret DNS-SD hints for a Harc V1 host.
///
/// These values are reachability and UI hints only. A client must not use any
/// field in this record as proof of host identity, adoption, or authorization.
public struct HarcBonjourServiceHintsV1: Equatable, Sendable {
    public static let serviceType = "_harc._tcp"

    public enum TXTKey {
        public static let displayName = "dn"
        public static let protocolMajor = "pmaj"
        public static let protocolMinor = "pmin"
        public static let capabilityBits = "caps"
        public static let uploadPort = "uport"

        static let required: Set<String> = [
            displayName,
            protocolMajor,
            protocolMinor,
            capabilityBits,
        ]
        static let allowed = required.union([uploadPort])
    }

    public let displayName: String
    public let protocolMajor: UInt16
    public let protocolMinor: UInt16
    public let capabilityBits: UInt64
    public let uploadPortHint: UInt16?

    public init(
        displayName: String,
        protocolMajor: UInt16,
        protocolMinor: UInt16,
        capabilityBits: UInt64,
        uploadPortHint: UInt16? = nil
    ) throws {
        try Self.validateDisplayName(displayName)
        guard protocolMajor > 0 else {
            throw HarcBonjourHintsV1Error.invalidProtocolMajor
        }
        if let uploadPortHint, uploadPortHint == 0 {
            throw HarcBonjourHintsV1Error.invalidUploadPort
        }

        self.displayName = displayName
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.capabilityBits = capabilityBits
        self.uploadPortHint = uploadPortHint
    }

    public init(txtRecord: [String: String]) throws {
        let keys = Set(txtRecord.keys)
        let missing = TXTKey.required.subtracting(keys)
        guard missing.isEmpty else {
            throw HarcBonjourHintsV1Error.missingTXTKey(
                missing.sorted().first!
            )
        }
        let unknown = keys.subtracting(TXTKey.allowed)
        guard unknown.isEmpty else {
            throw HarcBonjourHintsV1Error.unknownTXTKey(
                unknown.sorted().first!
            )
        }

        let displayName = txtRecord[TXTKey.displayName]!
        let protocolMajor: UInt16 = try Self.parseCanonicalDecimal(
            txtRecord[TXTKey.protocolMajor]!,
            field: .protocolMajor
        )
        let protocolMinor: UInt16 = try Self.parseCanonicalDecimal(
            txtRecord[TXTKey.protocolMinor]!,
            field: .protocolMinor
        )
        let capabilityBits = try Self.parseCapabilityBits(
            txtRecord[TXTKey.capabilityBits]!
        )
        let uploadPortHint: UInt16?
        if let encoded = txtRecord[TXTKey.uploadPort] {
            uploadPortHint = try Self.parseCanonicalDecimal(
                encoded,
                field: .uploadPort
            )
        } else {
            uploadPortHint = nil
        }

        try self.init(
            displayName: displayName,
            protocolMajor: protocolMajor,
            protocolMinor: protocolMinor,
            capabilityBits: capabilityBits,
            uploadPortHint: uploadPortHint
        )
    }

    /// Canonical string-only TXT representation. Fixed-width lowercase hex
    /// keeps the capability bitset unambiguous across implementations.
    public var txtRecord: [String: String] {
        var result = [
            TXTKey.displayName: displayName,
            TXTKey.protocolMajor: String(protocolMajor),
            TXTKey.protocolMinor: String(protocolMinor),
            TXTKey.capabilityBits: Self.encodeCapabilityBits(capabilityBits),
        ]
        if let uploadPortHint {
            result[TXTKey.uploadPort] = String(uploadPortHint)
        }
        return result
    }

    private enum DecimalField {
        case protocolMajor
        case protocolMinor
        case uploadPort
    }

    private static func parseCanonicalDecimal<T: FixedWidthInteger & UnsignedInteger>(
        _ encoded: String,
        field: DecimalField
    ) throws -> T {
        guard !encoded.isEmpty,
              encoded.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              (encoded == "0" || encoded.first != "0"),
              let value = T(encoded),
              String(value) == encoded else {
            switch field {
            case .protocolMajor:
                throw HarcBonjourHintsV1Error.invalidProtocolMajor
            case .protocolMinor:
                throw HarcBonjourHintsV1Error.invalidProtocolMinor
            case .uploadPort:
                throw HarcBonjourHintsV1Error.invalidUploadPort
            }
        }
        return value
    }

    private static func parseCapabilityBits(_ encoded: String) throws -> UInt64 {
        guard encoded.utf8.count == 16,
              encoded.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              }),
              let value = UInt64(encoded, radix: 16),
              encodeCapabilityBits(value) == encoded else {
            throw HarcBonjourHintsV1Error.invalidCapabilityBits
        }
        return value
    }

    private static func encodeCapabilityBits(_ value: UInt64) -> String {
        let encoded = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: 16 - encoded.count) + encoded
    }

    private static func validateDisplayName(_ value: String) throws {
        let bytes = value.utf8.count
        guard (1 ... 63).contains(bytes),
              value == value.precomposedStringWithCanonicalMapping,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw HarcBonjourHintsV1Error.invalidDisplayName
        }
    }
}

public enum HarcBonjourHintsV1Error: Error, Equatable, Sendable {
    case invalidDisplayName
    case invalidProtocolMajor
    case invalidProtocolMinor
    case invalidCapabilityBits
    case invalidUploadPort
    case missingTXTKey(String)
    case unknownTXTKey(String)
}
