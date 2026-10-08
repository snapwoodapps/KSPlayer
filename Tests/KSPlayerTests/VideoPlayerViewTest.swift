@testable import KSPlayer
import XCTest
#if canImport(UIKit) && !os(tvOS)
import AVKit
import UIKit
#endif

class VideoPlayerViewTest: XCTestCase {
    func testResize() {}
}

#if canImport(UIKit) && !os(tvOS)
extension VideoPlayerViewTest {
    func testRotatedVideoContainerUsesOrientedViewportForAspectFit() {
        let contentView = UIView()
        let container = RotatedVideoContainerView(contentView: contentView)
        container.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        container.contentMode = .scaleAspectFit
        container.rotationDegrees = 90

        container.layoutIfNeeded()

        XCTAssertEqual(contentView.contentMode, .scaleAspectFit)
        XCTAssertEqual(contentView.bounds.width, 844, accuracy: 0.001)
        XCTAssertEqual(contentView.bounds.height, 390, accuracy: 0.001)
        XCTAssertEqual(contentView.frame.width, container.bounds.width, accuracy: 0.001)
        XCTAssertEqual(contentView.frame.height, container.bounds.height, accuracy: 0.001)
    }

    func testRotatedVideoContainerRecognizesBothQuarterTurnDirections() {
        XCTAssertTrue(RotatedVideoContainerView.rotationSwapsAxes(90))
        XCTAssertTrue(RotatedVideoContainerView.rotationSwapsAxes(-90))
        XCTAssertTrue(RotatedVideoContainerView.rotationSwapsAxes(270))
        XCTAssertFalse(RotatedVideoContainerView.rotationSwapsAxes(0))
        XCTAssertFalse(RotatedVideoContainerView.rotationSwapsAxes(180))
    }

    func testZoomLayoutPreservesPlayerPresentationTransform() {
        let playerView = IOSVideoPlayerView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let player = VideoTransformTestPlayer(url: URL(fileURLWithPath: "/dev/null"), options: KSOptions())
        playerView.playerLayer.player = player

        let presentationTransform = CGAffineTransform(rotationAngle: .pi / 2)
        player.view.transform = presentationTransform

        playerView.player(layer: playerView.playerLayer, state: .readyToPlay)
        XCTAssertEqual(player.view.transform, presentationTransform)

        playerView.layoutSubviews()
        XCTAssertEqual(player.view.transform, presentationTransform)
        XCTAssertEqual(playerView.playerLayer.transform, .identity)
    }
}

private final class VideoTransformTestPlayer: MediaPlayerProtocol {
    weak var delegate: MediaPlayerDelegate?
    let view = UIView()
    let duration = TimeInterval.zero
    let naturalSize = CGSize(width: 1920, height: 1080)
    let currentPlaybackTime = TimeInterval.zero
    let playableTime = TimeInterval.zero
    let isPreparedToPlay = true
    let playbackState = MediaPlaybackState.paused
    let loadState = MediaLoadState.playable
    let isPlaying = false
    let seekable = false
    var isMuted = false
    var allowsExternalPlayback = false
    var usesExternalPlaybackWhileExternalScreenIsActive = false
    let isExternalPlaybackActive = false
    var playbackRate = Float(1)
    var playbackVolume = Float(1)
    var contentMode = UIView.ContentMode.scaleAspectFit
    var subtitleDataSouce: SubtitleDataSouce? { nil }

    @available(tvOS 14.0, *)
    var pipController: AVPictureInPictureController? { nil }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    var playbackCoordinator: AVPlaybackCoordinator {
        fatalError("Playback coordination is not used by this test")
    }

    required init(url _: URL, options _: KSOptions) {}

    func replace(url _: URL, options _: KSOptions) {}
    func prepareToPlay() {}
    func shutdown() {}
    func play() {}
    func pause() {}
    func enterBackground() {}
    func enterForeground() {}
    func seek(time _: TimeInterval, completion handler: ((Bool) -> Void)?) { handler?(true) }
    func thumbnailImageAtCurrentTime(handler: @escaping (UIImage?) -> Void) { handler(nil) }
    func tracks(mediaType _: AVFoundation.AVMediaType) -> [MediaPlayerTrack] { [] }
    func select(track _: MediaPlayerTrack) {}
}
#endif
