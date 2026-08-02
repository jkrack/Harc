import Foundation
import Testing
@testable import HarcDomain

@Suite("HarcDomain identifiers and revisions")
struct IdentifierAndRevisionTests {
    @Test("UUID-backed identifiers use stable single-value Codable encoding")
    func uuidIdentifierCodable() throws {
        let uuid = try #require(UUID(uuidString: "12345678-1234-4abc-8def-1234567890ab"))
        let identifier = LibraryID(uuid)

        let data = try JSONEncoder().encode(identifier)
        #expect(String(decoding: data, as: UTF8.self) == "\"12345678-1234-4abc-8def-1234567890ab\"")
        #expect(try JSONDecoder().decode(LibraryID.self, from: data) == identifier)

        let canonical = CanonicalRecordingID(uuid)
        #expect(try JSONDecoder().decode(CanonicalRecordingID.self, from: JSONEncoder().encode(canonical)) == canonical)
    }

    @Test("Digest-backed identifiers require exactly 32 bytes")
    func digestLengths() throws {
        #expect(throws: DomainValidationError.self) {
            try DeviceID(Data(repeating: 0x11, count: 31))
        }
        #expect(throws: DomainValidationError.self) {
            try HostAuthorityID(Data(repeating: 0x22, count: 33))
        }
        #expect(throws: DomainValidationError.self) {
            try CanonicalPCMHash(Data())
        }

        let bytes = Data(0..<32)
        let deviceID = try DeviceID(bytes)
        let encoded = try JSONEncoder().encode(deviceID)
        #expect(try JSONDecoder().decode(DeviceID.self, from: encoded) == deviceID)
        #expect(deviceID.description.count == 64)
    }

    @Test("Digest decoding cannot bypass length validation")
    func digestDecodeValidation() throws {
        let shortDataJSON = try JSONEncoder().encode(Data(repeating: 0x44, count: 31))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CanonicalPCMHash.self, from: shortDataJSON)
        }
    }

    @Test("Origin identity includes both device and recording UUID")
    func originIdentity() throws {
        let deviceA = try DeviceID(Data(repeating: 0x01, count: 32))
        let deviceB = try DeviceID(Data(repeating: 0x02, count: 32))
        let recordingUUID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let first = OriginRecordingID(deviceID: deviceA, recordingUUID: recordingUUID)
        let same = OriginRecordingID(deviceID: deviceA, recordingUUID: recordingUUID)
        let otherDevice = OriginRecordingID(deviceID: deviceB, recordingUUID: recordingUUID)

        #expect(first == same)
        #expect(first != otherDevice)
        #expect(Set([first, same, otherDevice]).count == 2)
        #expect(try JSONDecoder().decode(OriginRecordingID.self, from: JSONEncoder().encode(first)) == first)
    }

    @Test("Entity revisions are nonzero and increment with overflow protection")
    func revisions() throws {
        #expect(throws: DomainValidationError.zeroEntityRevision) {
            try EntityRevision(0)
        }
        #expect(try EntityRevision.initial.next() == EntityRevision(2))
        #expect(throws: DomainValidationError.self) {
            try EntityRevision(UInt64.max).next()
        }
        #expect(throws: DomainValidationError.self) {
            try EntityRevision(UInt64(Int64.max) + 1).signedInt64Value()
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EntityRevision.self, from: Data("0".utf8))
        }
    }

    @Test("Change cursor permits zero but checks signed persistence bounds")
    func cursors() throws {
        #expect(ChangeCursor.zero.rawValue == 0)
        #expect(try ChangeCursor.zero.next() == ChangeCursor(1))
        #expect(try ChangeCursor(signedValue: Int64.max).signedInt64Value() == Int64.max)
        #expect(throws: DomainValidationError.self) {
            try ChangeCursor(signedValue: -1)
        }
        #expect(throws: DomainValidationError.self) {
            try ChangeCursor(UInt64(Int64.max) + 1).signedInt64Value()
        }
        #expect(throws: DomainValidationError.self) {
            try ChangeCursor(UInt64.max).next()
        }
    }
}
