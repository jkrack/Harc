import Foundation

/// Portable canonical-library identity and writer state.
///
/// A normally disabled Host may retain its authority/state pair as dormant
/// consistency markers. A partial pair is never valid, and active Host mode
/// always requires both values.
public struct LibraryMetadata: Codable, Equatable, Hashable, Sendable {
    public let libraryID: LibraryID
    public let writerMode: LibraryWriterMode
    public let hostAuthorityID: HostAuthorityID?
    public let hostStateID: HostStateID?
    public let currentChangeCursor: ChangeCursor

    public init(
        libraryID: LibraryID,
        writerMode: LibraryWriterMode,
        hostAuthorityID: HostAuthorityID?,
        hostStateID: HostStateID?,
        currentChangeCursor: ChangeCursor
    ) throws {
        let hasAuthority = hostAuthorityID != nil
        let hasState = hostStateID != nil
        guard hasAuthority == hasState else {
            throw DomainValidationError.inconsistentHostIdentity
        }
        guard writerMode != .host || (hasAuthority && hasState) else {
            throw DomainValidationError.inconsistentHostIdentity
        }

        self.libraryID = libraryID
        self.writerMode = writerMode
        self.hostAuthorityID = hostAuthorityID
        self.hostStateID = hostStateID
        self.currentChangeCursor = currentChangeCursor
    }

    private enum CodingKeys: String, CodingKey {
        case libraryID
        case writerMode
        case hostAuthorityID
        case hostStateID
        case currentChangeCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                libraryID: container.decode(LibraryID.self, forKey: .libraryID),
                writerMode: container.decode(LibraryWriterMode.self, forKey: .writerMode),
                hostAuthorityID: container.decodeIfPresent(HostAuthorityID.self, forKey: .hostAuthorityID),
                hostStateID: container.decodeIfPresent(HostStateID.self, forKey: .hostStateID),
                currentChangeCursor: container.decode(ChangeCursor.self, forKey: .currentChangeCursor)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid LibraryMetadata invariants.",
                    underlyingError: error
                )
            )
        }
    }
}
