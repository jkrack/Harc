import Foundation
import HarcDomain
import Testing
@testable import HarcUI

@Suite("Host speaker identity presentation")
struct HarcSpeakerIdentityPresentationTests {
    @Test("status never treats a legacy identity or text label as confirmed")
    func confirmationStatus() throws {
        let person = PersonID.random()
        let cases: [(Bool?, String)] = [(true, "Confirmed"), (false, "Auto-matched"), (nil, "Confirmation unknown")]
        for (confirmed, expected) in cases {
            let label = try SpeakerLabel(speakerIndex: 0, displayName: "Alice", personID: person,
                identityRevision: EntityRevision(1), isUserConfirmed: confirmed)
            #expect(HarcSpeakerIdentityPresentation.statusText(label) == expected)
        }
        let text = try SpeakerLabel(speakerIndex: 0, displayName: "Saved name")
        #expect(HarcSpeakerIdentityPresentation.statusText(text) == "Label only")
    }
}
