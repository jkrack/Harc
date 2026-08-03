import HarcHost
import HarcDomain
import HarcTransfer

func replaceSecurityRegistryHighWaterMarkFromAnotherModule(
    _ store: InMemorySecurityRegistryHighWaterMarkStore
) async {
    await store.replaceForTesting(0)
}

func bypassCanonicalReceiptValidationFromAnotherModule(
    _ store: HarcHostStore,
    context: AuthenticatedDeviceContext,
    request: BeginHostUploadRequest,
    uploadID: UploadID
) async throws {
    let sessionCapabilities = try HostTransferSessionCapabilities(
        exactCapabilitiesSHA256: request.frozenProfile.negotiatedCapabilitiesSHA256,
        protocolVersion: request.frozenProfile.protocolVersion,
        selectedFeatureIDs: request.frozenProfile.requiredCapabilities,
        descriptorSchema: request.frozenProfile.descriptorSchema,
        encoding: request.frozenProfile.encoding,
        canonicalFormat: request.frozenProfile.canonicalFormat
    )
    _ = try await store.beginUpload(
        context: context,
        sessionCapabilities: sessionCapabilities,
        request: request
    )
    _ = try await store.reconciliation(
        for: uploadID,
        expectedUploadProfileSHA256: request.frozenProfile.profileSHA256,
        context: context
    )
}
