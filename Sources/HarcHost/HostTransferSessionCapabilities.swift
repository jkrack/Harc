import HarcDomain
import HarcTransfer

/// Transport-neutral semantic evidence from one authenticated session's exact
/// negotiated-capabilities payload. A protocol adapter constructs this value
/// only after validating and hashing the original wire bytes; HarcHost uses the
/// typed projection to bind upload admission without depending on a wire codec.
public struct HostTransferSessionCapabilities: Equatable, Sendable {
    public let exactCapabilitiesSHA256: NegotiatedCapabilitiesSHA256
    public let protocolVersion: TransferProtocolVersion
    public let selectedFeatureIDs: [TransferCapabilityID]
    public let descriptorSchemaID: TransferCapabilityID
    public let encoding: LosslessEncodingConfiguration
    public let canonicalFormat: CanonicalPCMFormat

    public init(
        exactCapabilitiesSHA256: NegotiatedCapabilitiesSHA256,
        protocolVersion: TransferProtocolVersion,
        selectedFeatureIDs: [TransferCapabilityID],
        descriptorSchema: ChunkDescriptorSchema,
        encoding: LosslessEncodingConfiguration,
        canonicalFormat: CanonicalPCMFormat
    ) throws {
        try self.init(
            exactCapabilitiesSHA256: exactCapabilitiesSHA256,
            protocolVersion: protocolVersion,
            selectedFeatureIDs: selectedFeatureIDs,
            descriptorSchemaID: TransferCapabilityID(descriptorSchema.rawValue),
            encoding: encoding,
            canonicalFormat: canonicalFormat
        )
    }

    /// Accepts the validated wire identifier without pretending a future
    /// schema is a known `ChunkDescriptorSchema` case. Compatibility admission
    /// will reject it against a V1 frozen profile without mutating host state.
    public init(
        exactCapabilitiesSHA256: NegotiatedCapabilitiesSHA256,
        protocolVersion: TransferProtocolVersion,
        selectedFeatureIDs: [TransferCapabilityID],
        descriptorSchemaID: TransferCapabilityID,
        encoding: LosslessEncodingConfiguration,
        canonicalFormat: CanonicalPCMFormat
    ) throws {
        guard selectedFeatureIDs == selectedFeatureIDs.sorted() else {
            throw TransferValidationError.invalidOrdering(
                field: "HostTransferSessionCapabilities.selectedFeatureIDs"
            )
        }
        guard Set(selectedFeatureIDs).count == selectedFeatureIDs.count else {
            throw TransferValidationError.duplicateIdentifier(
                field: "HostTransferSessionCapabilities.selectedFeatureIDs"
            )
        }
        self.exactCapabilitiesSHA256 = exactCapabilitiesSHA256
        self.protocolVersion = protocolVersion
        self.selectedFeatureIDs = selectedFeatureIDs
        self.descriptorSchemaID = descriptorSchemaID
        self.encoding = encoding
        self.canonicalFormat = canonicalFormat
    }

    /// A new upload must bind the exact capabilities object frozen into its
    /// profile as well as every semantic selection represented by that object.
    func validateInitialAdmission(against profile: FrozenUploadProfile) throws {
        try validateCompatibleAdmission(against: profile)
        guard exactCapabilitiesSHA256 == profile.negotiatedCapabilitiesSHA256 else {
            throw TransferValidationError.profileMismatch(
                field: "negotiatedCapabilitiesSHA256"
            )
        }
    }

    /// A replay or generation reopen may arrive through a later negotiated
    /// capabilities object. Its exact hash may differ because unrelated
    /// features were added, but all frozen transfer semantics and every
    /// profile-required feature must remain compatible.
    func validateCompatibleAdmission(against profile: FrozenUploadProfile) throws {
        guard protocolVersion == profile.protocolVersion else {
            throw TransferValidationError.profileMismatch(field: "protocolVersion")
        }
        guard descriptorSchemaID.rawValue == profile.descriptorSchema.rawValue else {
            throw TransferValidationError.profileMismatch(field: "descriptorSchema")
        }
        guard encoding.codec == profile.encoding.codec else {
            throw TransferValidationError.profileMismatch(field: "encoding.codec")
        }
        guard encoding.container == profile.encoding.container else {
            throw TransferValidationError.profileMismatch(field: "encoding.container")
        }
        guard encoding.flacCompressionLevel == profile.encoding.flacCompressionLevel else {
            throw TransferValidationError.profileMismatch(
                field: "encoding.flacCompressionLevel"
            )
        }
        guard canonicalFormat == profile.canonicalFormat else {
            throw TransferValidationError.profileMismatch(field: "canonicalFormat")
        }

        let selectedFeatures = Set(selectedFeatureIDs)
        guard profile.requiredCapabilities.allSatisfy(selectedFeatures.contains) else {
            throw TransferValidationError.profileMismatch(field: "requiredCapabilities")
        }
    }
}
