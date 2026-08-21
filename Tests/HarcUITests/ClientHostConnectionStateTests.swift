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
    }
}
