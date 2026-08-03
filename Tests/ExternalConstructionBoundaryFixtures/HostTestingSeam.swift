import HarcHost

func replaceSecurityRegistryHighWaterMarkFromAnotherModule(
    _ store: InMemorySecurityRegistryHighWaterMarkStore
) async {
    await store.replaceForTesting(0)
}
