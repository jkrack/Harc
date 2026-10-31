import AVFAudio
import XCTest
@testable import HarcMobile

@MainActor
final class HarcMobilePlaybackSessionTests: XCTestCase {
    func testReactivationRequiresCurrentOwnerAndCannotInterruptCapture() throws {
        let fixture = Fixture()
        let first = try fixture.session.acquire {}
        try fixture.session.reactivate(first)
        XCTAssertEqual(fixture.activations, 2)
        let second = try fixture.session.acquire {}
        XCTAssertThrowsError(try fixture.session.reactivate(first))
        XCTAssertEqual(fixture.activations, 3)
        fixture.session.beginCapture()
        XCTAssertThrowsError(try fixture.session.reactivate(second))
        fixture.session.endCapture()
        XCTAssertThrowsError(try fixture.session.reactivate(second))
        XCTAssertEqual(fixture.activations, 3)
    }

    func testIdleRowDisappearanceCannotReleaseCaptureOrAnotherPlayer() async throws {
        let fixture = Fixture()
        let idle = fixture.controller()
        let playing = fixture.controller()
        await playing.playOrPause()
        idle.stop()
        XCTAssertEqual(fixture.deactivations, 0)
        XCTAssertEqual(playing.state, .playing)
        fixture.session.beginCapture()
        XCTAssertEqual(fixture.deactivations, 1)
        idle.stop()
        playing.stop()
        XCTAssertEqual(fixture.deactivations, 1)
    }

    func testOwnedReleaseIsExactlyOnceAndOldCompletionCannotReleaseNewPlayer() async {
        let fixture = Fixture()
        let firstPlayer = Player()
        let first = fixture.controller(player: firstPlayer)
        let second = fixture.controller()
        await first.playOrPause()
        await second.playOrPause()
        XCTAssertEqual(first.state, .idle)
        XCTAssertEqual(firstPlayer.stops, 1)
        first.playbackFinished(firstPlayer, successfully: true)
        first.stop()
        XCTAssertEqual(fixture.deactivations, 0)
        second.stop()
        second.stop()
        XCTAssertEqual(fixture.deactivations, 1)
    }

    func testCompletionReleasesOnlyItsOwnSessionOnce() async {
        let fixture = Fixture()
        let player = Player()
        let controller = fixture.controller(player: player)
        await controller.playOrPause()
        controller.playbackFinished(player, successfully: true)
        controller.playbackFinished(player, successfully: true)
        controller.stop()
        XCTAssertEqual(fixture.deactivations, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testPlayerConstructionAndStartFailuresReleaseSuccessfulActivation() async {
        let fixture = Fixture()
        let controller = HarcMobileLocalRecordingAudioController(
            url: URL(fileURLWithPath: "/synthetic.wav"), session: fixture.session,
            makePlayer: { _ in throw Failure.injected }
        )
        await controller.playOrPause()
        controller.stop()
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertEqual(fixture.deactivations, 1)
        let player = Player()
        player.canPlay = false
        let failedStart = fixture.controller(player: player)
        await failedStart.playOrPause()
        failedStart.stop()
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(fixture.deactivations, 2)
    }

    func testActivationFailureDoesNotReleaseExistingOwner() async {
        let fixture = Fixture()
        let owner = fixture.controller()
        await owner.playOrPause()
        fixture.failActivation = true
        let failed = fixture.controller()
        await failed.playOrPause()
        failed.stop()
        XCTAssertEqual(owner.state, .playing)
        XCTAssertEqual(fixture.deactivations, 0)
        owner.stop()
        XCTAssertEqual(fixture.deactivations, 1)
    }

    func testFailedResumeReleasesOwnedSession() async {
        let fixture = Fixture()
        let player = Player()
        let controller = fixture.controller(player: player)
        await controller.playOrPause()
        await controller.playOrPause()
        player.canPlay = false
        await controller.playOrPause()
        controller.stop()
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(fixture.deactivations, 1)
    }

    func testCaptureClaimBlocksLatePlayThroughPermissionAndStartup() async {
        let fixture = Fixture()
        let player = Player()
        let controller = fixture.controller(player: player)
        // Capture claims the session before requesting permission, retaining it
        // throughout starting/recording/stopping. No microphone is used here.
        fixture.session.beginCapture()
        await controller.playOrPause()
        controller.stop() // navigation away while capture owns the session
        XCTAssertEqual(fixture.activations, 0)
        XCTAssertEqual(fixture.deactivations, 0)
        XCTAssertEqual(player.plays, 0)
        fixture.session.endCapture()
        await controller.playOrPause()
        XCTAssertEqual(player.plays, 1)
        controller.stop()
        XCTAssertEqual(fixture.deactivations, 1)
    }

    func testCaptureRevokesPausedPlaybackAndRejectsItsLateCompletion() async {
        let fixture = Fixture()
        let player = Player()
        let controller = fixture.controller(player: player)
        await controller.playOrPause()
        await controller.playOrPause()
        XCTAssertEqual(controller.state, .paused)
        fixture.session.beginCapture()
        XCTAssertEqual(controller.state, .idle)
        let releasedBeforeCapture = fixture.deactivations
        controller.playbackFinished(player, successfully: false)
        controller.stop()
        await controller.playOrPause()
        XCTAssertEqual(fixture.deactivations, releasedBeforeCapture)
        XCTAssertEqual(player.plays, 1)
    }

    private enum Failure: Error { case injected }

    @MainActor
    private final class Fixture {
        var activations = 0
        var deactivations = 0
        var failActivation = false
        lazy var session = HarcMobilePlaybackSession(
            activate: { [unowned self] in
                if failActivation { throw Failure.injected }
                activations += 1
            },
            deactivate: { [unowned self] in deactivations += 1 }
        )
        func controller(player: Player = Player()) -> HarcMobileLocalRecordingAudioController {
            HarcMobileLocalRecordingAudioController(
                url: URL(fileURLWithPath: "/synthetic.wav"),
                session: session, makePlayer: { _ in player }
            )
        }
    }

    @MainActor
    private final class Player: HarcMobileLocalAudioPlayer {
        var delegate: (any AVAudioPlayerDelegate)?
        var isPlaying = false
        var canPlay = true
        var plays = 0
        var stops = 0
        func prepareToPlay() -> Bool { true }
        func play() -> Bool { plays += 1; isPlaying = canPlay; return canPlay }
        func pause() { isPlaying = false }
        func stop() { stops += 1; isPlaying = false }
    }
}
