import HarcHost
import HarcDomain

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
    _ = try await store.beginUpload(context: context, request: request)
    _ = try await store.reconciliation(for: uploadID, context: context)
}
