import Foundation
import HarcClientStore
import HarcDomain
import HarcIdentity
import HarcProtocol
import HarcTransfer

enum HarcMobileMetadataMutation: Equatable, Sendable {
    case setTitle(String?)
    case replaceTags([String])
    case setSpeakerLabel(index: UInt32, displayName: String?)
    case assignSpeakerIdentity(index: UInt32, personID: PersonID?)
    case setNotesMarkdown(String?)
    case setPinned(Bool)

    var queueKind: OfflineMetadataMutationKind {
        switch self {
        case .setTitle: .setTitle
        case .replaceTags: .setTags
        case .setSpeakerLabel: .setSpeakerLabel
        case .assignSpeakerIdentity: .assignSpeakerIdentity
        case .setNotesMarkdown: .setNotes
        case .setPinned: .setPinned
        }
    }
}

struct HarcMobileSignedMetadataMutation: Sendable {
    let queued: OfflineMetadataMutation

    init(
        mutation: HarcMobileMetadataMutation,
        summary: LibraryRecordingSummary,
        adoption: ValidatedClientAdoptionEvidence,
        identity: InstallationSigningIdentity,
        now: Date = Date()
    ) throws {
        guard adoption.grant.deviceID == identity.deviceID,
              adoption.hostTrust.libraryID == adoption.grant.libraryID,
              adoption.hostTrust.hostAuthorityID
                == adoption.grant.hostAuthorityID else {
            throw HarcMobileLibraryError.malformedResponse
        }
        let operationID = OperationID(UUID())
        let issuedAt = try Self.unixMilliseconds(now)
        let expiresAt = issuedAt.addingReportingOverflow(
            HarcProtocolLimits.initialCommandLifetimeMilliseconds
        )
        guard !expiresAt.overflow else {
            throw HarcMobileLibraryError.malformedResponse
        }

        var payload = Harc_V1_MetadataMutationV1()
        payload.protocol = HarcProtocolVersion.v1.protobufV1()
        payload.libraryID = Harc_V1_LibraryIDV1(adoption.grant.libraryID)
        payload.hostAuthorityID = Harc_V1_HostAuthorityIDV1(
            adoption.grant.hostAuthorityID
        )
        payload.requestingDeviceID = Harc_V1_DeviceIDV1(identity.deviceID)
        payload.grantID = Harc_V1_GrantIDV1(adoption.grant.grantID)
        payload.grantEpoch = adoption.grant.registryEpoch
        payload.operationID = Harc_V1_OperationIDV1(operationID)
        payload.issuedAtUnixMs = issuedAt
        payload.expiresAtUnixMs = expiresAt.partialValue
        payload.canonicalRecordingID = Harc_V1_CanonicalRecordingIDV1(
            summary.canonicalID
        )
        payload.expectedRevision = summary.revision.rawValue
        payload.mutation = try Self.protobufMutation(mutation)

        let exactPayload = try payload.serializedData()
        let envelope = try HarcSignedEnvelopeV1(
            messageType: .metadataMutation,
            protocolVersion: .v1,
            libraryID: adoption.grant.libraryID,
            hostAuthorityID: adoption.grant.hostAuthorityID,
            signerDeviceID: identity.deviceID,
            grantID: adoption.grant.grantID.rawValue,
            grantEpoch: adoption.grant.registryEpoch,
            operationID: operationID.rawValue,
            issuedAtUnixMilliseconds: issuedAt,
            expiresAtUnixMilliseconds: expiresAt.partialValue,
            payloadType: .metadataMutation,
            expectedRevision: summary.revision.rawValue,
            payloadSHA256: HarcSignedEnvelopeV1.payloadDigest(exactPayload)
        )
        let signed = try HarcSignedObjectV1.sign(
            header: envelope,
            exactPayloadBytes: exactPayload,
            using: identity
        )
        guard case .metadataMutation = try signed
            .authenticateRegisteredPayload(
                using: identity.publicKey,
                purpose: HarcSignedObjectAuthenticationPurposeV1
                    .historicalEvidence
            ).payload else {
            throw HarcMobileLibraryError.malformedResponse
        }
        queued = try OfflineMetadataMutation(
            operationID: operationID,
            libraryID: adoption.grant.libraryID,
            canonicalRecordingID: summary.canonicalID,
            expectedRevision: summary.revision,
            kind: mutation.queueKind,
            exactPayload: signed.exactFramedBytes,
            createdAt: now
        )
    }

    static func request(
        for queued: OfflineMetadataMutation
    ) -> Harc_V1_ApplyMetadataMutationRequestV1 {
        var request = Harc_V1_ApplyMetadataMutationRequestV1()
        request.protocol = HarcProtocolVersion.v1.protobufV1()
        request.exactSignedMetadataMutation.framedBytes = queued.exactPayload
        return request
    }

    private static func protobufMutation(
        _ mutation: HarcMobileMetadataMutation
    ) throws -> Harc_V1_MetadataMutationV1.OneOf_Mutation {
        switch mutation {
        case .setTitle(let title):
            var value = Harc_V1_SetTitleMutationV1()
            if let title {
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HarcMobileLibraryError.invalidMetadataValue
                }
                value.title = title
            }
            return .setTitle(value)
        case .replaceTags(let tags):
            let canonical = Array(Set(tags.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }).filter { !$0.isEmpty }).sorted()
            var value = Harc_V1_ReplaceTagsMutationV1()
            value.tags = canonical
            return .replaceTags(value)
        case .setSpeakerLabel(let index, let displayName):
            var value = Harc_V1_SetSpeakerLabelMutationV1()
            value.speakerIndex = index
            if let displayName {
                guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HarcMobileLibraryError.invalidMetadataValue
                }
                value.displayName = displayName
            }
            return .setSpeakerLabel(value)
        case .assignSpeakerIdentity(let index, let personID):
            var value = Harc_V1_AssignSpeakerIdentityMutationV1()
            value.speakerIndex = index
            if let personID { value.personID = Harc_V1_PersonIDV1(personID) }
            return .assignSpeakerIdentity(value)
        case .setNotesMarkdown(let markdown):
            var value = Harc_V1_SetNotesMarkdownMutationV1()
            if let markdown {
                guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HarcMobileLibraryError.invalidMetadataValue
                }
                value.markdown = markdown
            }
            return .setNotesMarkdown(value)
        case .setPinned(let pinned):
            var value = Harc_V1_SetPinnedMutationV1()
            value.pinned = pinned
            return .setPinned(value)
        }
    }

    private static func unixMilliseconds(_ date: Date) throws -> UInt64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0,
              value <= 9_007_199_254_740_991 else {
            throw HarcMobileLibraryError.malformedResponse
        }
        return UInt64(value.rounded(.down))
    }
}
