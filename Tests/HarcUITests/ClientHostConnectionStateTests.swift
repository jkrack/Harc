import Foundation
import Testing
@testable import HarcUI

struct ClientHostConnectionStateTests {
    @Test("local Client readiness is not treated as Host connectivity")
    func pairingAndConnectivityRemainDistinct() {
        let notPaired = ClientHostConnectionState.notPaired(pending: 3)
        #expect(!notPaired.isPaired)
        #expect(!notPaired.isConnected)
        #expect(notPaired.pendingCount == 3)
        #expect(notPaired.lastContact == nil)

        let contact = Date(timeIntervalSince1970: 1_700_000_000)
        let paired = ClientHostConnectionState.paired(
            lastContact: contact,
            pending: 2
        )
        #expect(paired.isPaired)
        #expect(!paired.isConnected)
        #expect(paired.lastContact == contact)

        let connected = ClientHostConnectionState.connected(
            lastContact: contact,
            pending: 1
        )
        #expect(connected.isPaired)
        #expect(connected.isConnected)
        #expect(connected.pendingCount == 1)
    }

    @Test("attention states preserve last authenticated contact")
    func attentionPreservesConnectionEvidence() {
        let contact = Date(timeIntervalSince1970: 1_700_000_000)
        let state = ClientHostConnectionState.needsAttention(
            message: "Host unavailable",
            lastContact: contact,
            pending: 15
        )
        #expect(state.isPaired)
        #expect(!state.isConnected)
        #expect(state.lastContact == contact)
        #expect(state.pendingCount == 15)
        #expect(state.canRetryConnection)

        let blocked = ClientHostConnectionState.securityBlocked(
            message: "Pair again",
            lastContact: contact,
            pending: 15
        )
        #expect(!blocked.canRetryConnection)
    }

    @Test("health axes preserve mixed states without a false all-green summary")
    func independentHealthAxes() {
        let contact = Date(timeIntervalSince1970: 1_700_000_000)
        let retryAt = contact.addingTimeInterval(300)
        let snapshot = ClientHostHealthSnapshot(
            trust: .adopted,
            route: .direct,
            session: .idle,
            recordings: .current,
            processing: .retrying(2, "Host busy"),
            speakers: .needsAttention(repairing: 0, review: 1),
            lastAuthenticatedAt: contact,
            nextAutomaticRetryAt: retryAt
        )

        #expect(snapshot.trust == .adopted)
        #expect(snapshot.route == .direct)
        #expect(snapshot.session == .idle)
        #expect(snapshot.recordings == .current)
        #expect(snapshot.processing == .retrying(2, "Host busy"))
        #expect(snapshot.speakers == .needsAttention(repairing: 0, review: 1))
        #expect(snapshot.lastAuthenticatedAt == contact)
        #expect(snapshot.nextAutomaticRetryAt == retryAt)
    }
}
