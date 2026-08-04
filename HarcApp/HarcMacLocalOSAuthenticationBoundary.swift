import HarcDomain
import HarcHost
import HarcIdentity
import LocalAuthentication

/// Interactive macOS authority boundary for grants broader than the minimal
/// capture-only set. Transport code cannot construct or bypass this value; the
/// resident app injects it while opening HarcHost.db.
struct HarcMacLocalOSAuthenticationBoundary:
    HostLocalOSAuthenticationBoundary, Sendable
{
    func authorizeInitialGrantExpansion(
        for deviceID: DeviceID,
        clientKind: AdoptedClientKind,
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool {
        await evaluate(
            reason: "Allow this \(clientKind == .mobile ? "iPhone" : "Mac") to access the selected Harc library data."
        )
    }

    func authorizeGrantScopeChange(
        for deviceID: DeviceID,
        currentScopes: [AuthorizationScope],
        requestedScopes: [AuthorizationScope]
    ) async throws -> Bool {
        await evaluate(
            reason: "Approve this change to a paired device's Harc library access."
        )
    }

    func authorizeSameKeyReadoption(
        for deviceID: DeviceID
    ) async throws -> Bool {
        await evaluate(
            reason: "Approve re-pairing this existing Harc device identity."
        )
    }

    private func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        ) else { return false }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}
