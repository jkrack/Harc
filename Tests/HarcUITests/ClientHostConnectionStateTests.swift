import Foundation
import Testing
@testable import HarcUI

struct ClientHostConnectionStateTests {
    @Test("archive completion does not claim queued recordings are on Host")
    func pendingRecoveryDelivery() {
        let report = ClientRecoverSyncReport(mastersFound: 2, sidecarsFound: 4,
            sidecarsRebuilt: 0, outboxesRepaired: 0, alreadyTracked: 4,
            retryRequested: 2, alreadyOnHost: 2, securityBlocked: 0, issues: [])
        #expect(report.headline == "Archive check finished; Host delivery is pending")
        #expect(report.detail.contains("Host delivery queued for 2"))
        let blocked = ClientRecoverSyncReport(mastersFound: 2, sidecarsFound: 4,
            sidecarsRebuilt: 0, outboxesRepaired: 0, alreadyTracked: 4,
            retryRequested: 2, alreadyOnHost: 2, securityBlocked: 1, issues: [])
        #expect(blocked.headline.contains("needing attention"))
        let hostOnly = ClientRecoverSyncReport(mastersFound: 0, sidecarsFound: 2,
            sidecarsRebuilt: 0, outboxesRepaired: 0, alreadyTracked: 2,
            retryRequested: 0, alreadyOnHost: 2, securityBlocked: 0, issues: [])
        #expect(hostOnly.headline == "All Client recordings are on the Host")
    }

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
