import Testing
@testable import Harc

@Suite("Desktop Client Host-audio policy")
struct HarcDesktopClientAudioPolicyTests {
    @Test("download denial always disables retention")
    func downloadDenialDisablesRetention() {
        let policy = HarcLibraryAudioPolicy(
            allowsDownload: false,
            retainsAfterPlayback: true
        )
        #expect(!policy.allowsDownload)
        #expect(!policy.retainsAfterPlayback)
    }

    @Test("privacy-first playback can download without retaining")
    func playbackOnly() {
        let policy = HarcLibraryAudioPolicy(
            allowsDownload: true,
            retainsAfterPlayback: false
        )
        #expect(policy.allowsDownload)
        #expect(!policy.retainsAfterPlayback)
    }
}
