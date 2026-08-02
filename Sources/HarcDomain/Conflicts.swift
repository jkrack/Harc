import Foundation

public struct RevisionedValue<Value: Sendable>: Sendable {
    public let value: Value
    public let revision: EntityRevision
    public let changeCursor: ChangeCursor

    public init(value: Value, revision: EntityRevision, changeCursor: ChangeCursor) {
        self.value = value
        self.revision = revision
        self.changeCursor = changeCursor
    }
}

extension RevisionedValue: Equatable where Value: Equatable {}
extension RevisionedValue: Hashable where Value: Hashable {}
extension RevisionedValue: Codable where Value: Codable {}

public struct RevisionConflict<Value: Sendable>: Sendable {
    public let canonicalID: CanonicalRecordingID
    public let expectedRevision: EntityRevision
    public let currentRevision: EntityRevision
    public let currentValue: Value

    public init(
        canonicalID: CanonicalRecordingID,
        expectedRevision: EntityRevision,
        currentRevision: EntityRevision,
        currentValue: Value
    ) throws {
        guard expectedRevision != currentRevision else {
            throw DomainValidationError.matchingConflictRevisions
        }
        self.canonicalID = canonicalID
        self.expectedRevision = expectedRevision
        self.currentRevision = currentRevision
        self.currentValue = currentValue
    }
}

extension RevisionConflict: Equatable where Value: Equatable {}
extension RevisionConflict: Hashable where Value: Hashable {}

public enum CompareAndSwapResult<Value: Sendable>: Sendable {
    case applied(RevisionedValue<Value>)
    case conflict(RevisionConflict<Value>)
}

extension CompareAndSwapResult: Equatable where Value: Equatable {}
extension CompareAndSwapResult: Hashable where Value: Hashable {}
