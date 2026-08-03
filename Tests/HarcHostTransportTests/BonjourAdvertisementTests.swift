#if canImport(Network)
import Foundation
import HarcProtocol
@testable import HarcHostTransport
import Network
import Testing

@Suite("Bonjour listener advertisement")
struct BonjourAdvertisementTests {
    @Test("advertisement attaches exact V1 service to the gRPC listener")
    func attachesToSuppliedListener() async throws {
        let generationID = UUID()
        let hints = try makeHints()
        let advertisement = HarcBonjourListenerAdvertisement(
            generationID: generationID,
            hints: hints
        )
        let listener = try NWListener(using: .tcp)

        try await advertisement.arm(forGenerationID: generationID)
        try await advertisement.attach(
            to: listener,
            generationID: generationID
        )

        let service = try #require(listener.service)
        #expect(service.name == "Studio Host")
        #expect(service.type == "_harc._tcp")
        #expect(service.domain == nil)
        #expect(service.txtRecordObject?.dictionary == hints.txtRecord)
        #expect(await advertisement.stateSnapshot == .attached)
    }

    @Test("factory readiness can wait on registration without live networking")
    func registrationReadinessSeam() async throws {
        let generationID = UUID()
        let advertisement = HarcBonjourListenerAdvertisement(
            generationID: generationID,
            hints: try makeHints()
        )
        let listener = try NWListener(using: .tcp)
        try await advertisement.arm(forGenerationID: generationID)
        try await advertisement.attach(to: listener, generationID: generationID)

        let waiter = Task {
            try await advertisement.waitUntilRegistered(
                generationID: generationID
            )
        }
        await advertisement.reportRegistrationAddedForTesting(
            generationID: generationID
        )
        try await waiter.value
        #expect(await advertisement.stateSnapshot == .registered)
    }

    @Test("withdraw tombstones first, clears service, and rejects late attach")
    func withdrawalTombstone() async throws {
        let generationID = UUID()
        let advertisement = HarcBonjourListenerAdvertisement(
            generationID: generationID,
            hints: try makeHints()
        )
        let listener = try NWListener(using: .tcp)
        try await advertisement.arm(forGenerationID: generationID)
        try await advertisement.attach(to: listener, generationID: generationID)

        await advertisement.withdraw(generationID: generationID)

        #expect(listener.service == nil)
        #expect(await advertisement.stateSnapshot == .withdrawn)
        await #expect(throws: HarcBonjourAdvertisementError.generationWithdrawn) {
            try await advertisement.arm(forGenerationID: generationID)
        }
        let lateListener = try NWListener(using: .tcp)
        await #expect(throws: HarcBonjourAdvertisementError.generationWithdrawn) {
            try await advertisement.attach(
                to: lateListener,
                generationID: generationID
            )
        }
        #expect(lateListener.service == nil)
    }

    @Test("generation mismatch cannot mutate another generation's listener")
    func generationBinding() async throws {
        let generationID = UUID()
        let advertisement = HarcBonjourListenerAdvertisement(
            generationID: generationID,
            hints: try makeHints()
        )

        await #expect(throws: HarcBonjourAdvertisementError.generationMismatch) {
            try await advertisement.arm(forGenerationID: UUID())
        }
        #expect(await advertisement.stateSnapshot == .idle)
    }

    private func makeHints() throws -> HarcBonjourServiceHintsV1 {
        try HarcBonjourServiceHintsV1(
            displayName: "Studio Host",
            protocolMajor: 1,
            protocolMinor: 0,
            capabilityBits: 5,
            uploadPortHint: 8_444
        )
    }
}
#endif
