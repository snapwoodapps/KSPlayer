#!/usr/bin/env python3
"""Exercise the production playback clock methods without a GPU or audio device.

Optionally pass an MP4 to replay its decoded video timestamps through the scheduler.
Hardware audio routing and visual playback still need a device replay.
"""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


repo = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func").replace("public func", "func").replace("@objc ", "")


metal = (repo / "Sources/KSPlayer/MEPlayer/MetalPlayView.swift").read_text()
item = (repo / "Sources/KSPlayer/MEPlayer/MEPlayerItem.swift").read_text()
audio = (repo / "Sources/KSPlayer/MEPlayer/AudioEnginePlayer.swift").read_text()
player = (repo / "Sources/KSPlayer/MEPlayer/KSMEPlayer.swift").read_text()
layer = (repo / "Sources/KSPlayer/AVPlayer/KSPlayerLayer.swift").read_text()

production = """import Foundation
import Combine
import CoreMedia
import AudioToolbox
extension MetalPlayView {
""" + "\n".join(declaration(metal, marker) for marker in [
    "    private func observeFrameRate()", "    private func configureDisplayLink()", "    var isPaused: Bool",
    "    func restoreLastFrame()", "    private func drawView(", "    func clear()",
]) + """
}
extension MEPlayerItem {
""" + "\n".join(declaration(item, marker) for marker in [
    "    func getVideoOutputRender(", "    func setVideo(time:", "    func setAudio(time:",
    "    func resetVideoClock()",
]) + """
}
extension AudioEnginePlayer {
""" + "\n".join(declaration(audio, marker) for marker in [
    "    private func updateOutputLatency()", "    private func audioPlayerDidRenderSample(",
]) + "\n}\nextension KSMEPlayer {\n" + "\n".join(declaration(player, marker) for marker in [
    "    private func playOrPause()", "    public func enterForeground()",
]) + "\n}\nextension KSPlayerLayer {\n" + declaration(layer, "    @objc private func enterForeground()") + "\n}\n"
production += declaration(metal, "private final class VideoDisplayLinkTarget:").replace("private final class", "final class").replace("func draw(", "@objc func draw(")
production = production.replace("#if canImport(UIKit)", "#if TEST_UIKIT")

support = r"""
import Foundation
import Combine
import CoreMedia
import AudioToolbox

enum TestClock { static var now = 1000.0 }
func CACurrentMediaTime() -> Double { TestClock.now }
func runInMainqueue(_ action: () -> Void) { action() }
final class Options {
    @Published var preferredFramesPerSecond: Float = 60
    var audioDelay = 0.0
    var usesDisplayLayer = true
    func isUseDisplayLayer() -> Bool { usesDisplayLayer }
}
final class FrameTimer {
    var intervals = [Double]()
    var suspensionCount = 1
    func suspend() { suspensionCount += 1; precondition(suspensionCount == 1) }
    func resume() { suspensionCount -= 1; precondition(suspensionCount == 0) }
    func schedule(deadline: DispatchTime, repeating: Double) {
        precondition(Thread.isMainThread)
        intervals.append(repeating)
    }
}
final class MetalPlayView {
    let options = Options()
    let timer = FrameTimer()
    var frameRateCancellable: AnyCancellable?
    var displayLink: CADisplayLink?
    let view = OutputView()
    let displayLayer = DisplayLayer()
    let render = Render()
    var pixelBuffer: Double?
    var videoInfo: Int?
    var renderSource: MEPlayerItem?
    var drawnFrames = [Double]()
    func draw(pixelBuffer: Double) { drawnFrames.append(pixelBuffer) }
}
final class CADisplayLink: NSObject {
    let target: NSObject
    let selector: Selector
    var isPaused = false
    var targetTimestamp = 0.0
    var mode: RunLoop.Mode?
    init(target: NSObject, selector: Selector) { self.target = target; self.selector = selector }
    func add(to: RunLoop, forMode: RunLoop.Mode) { mode = forMode }
    func fire() { _ = target.perform(selector, with: self) }
}
final class OutputView {
    var isPaused = true
    var isHidden = true
    var currentDrawable: Int? = 1
    var currentRenderPassDescriptor: Int? = 1
}
final class DisplayLayer {
    enum Status { case rendering, failed }
    var status = Status.rendering
    var isReadyForMoreMediaData = true
    var flushCount = 0
    func flush() { flushCount += 1 }
    func flushAndRemoveImage() { flush() }
}
final class Render {
    func clear(drawable: Int, renderPassDescriptor: Int) {}
}
enum PlaybackState { case playing, paused, seeking }
enum LoadState { case loading, playable }
final class PlayerDelegate {
    func changeLoadState(player: KSMEPlayer) {}
}
final class KSMEPlayer {
    let playerItem = MEPlayerItem()
    let videoOutput = MetalPlayView()
    var audioOutput: OutputView? = OutputView()
    var playbackState = PlaybackState.paused
    var loadState = LoadState.playable
    var delegate: PlayerDelegate?
    init() { videoOutput.renderSource = playerItem }
}
final class KSPlayerLayer {
    var player: KSMEPlayer?
}
final class VideoVTBFrame {
    let cmtime: CMTime
    var seconds: Double { cmtime.seconds }
    var corePixelBuffer: Double? { seconds }
    init(_ seconds: Double) { cmtime = CMTime(value: Int64((seconds * 60_000_000).rounded()), timescale: 60_000_000) }
}
final class Track {
    var frames: [VideoVTBFrame]
    var frameCount: Int { frames.count }
    var emptyReads = 0
    var reads = 0
    var refill = false
    init(_ pts: [Double]) { frames = pts.map(VideoVTBFrame.init) }
    func getOutputRender(where predicate: ((VideoVTBFrame) -> Bool)?) -> VideoVTBFrame? {
        reads += 1
        guard let first = frames.first else { emptyReads += 1; return nil }
        guard predicate?(first) ?? true else { return nil }
        frames.removeFirst()
        if refill { frames.append(VideoVTBFrame(first.seconds)) }
        return first
    }
}
enum State { case reading, seeking }
final class MEPlayerItem {
    var videoTrack: Track?
    let options = Options()
    var currentPlaybackTime = 0.0
    var startTime = 0.0
    var isAudioStalled = false
    var videoMediaTime = CACurrentMediaTime()
    var videoClockDelay = 0.0
    let playbackClockLock = NSLock()
    var audioClock: (time: TimeInterval, hostTime: TimeInterval, rate: Double)?
    var state = State.reading
}
final class AudioSource {
    var outputPresentationLatency = 0.0
}
struct Timebase {
    func cmtime(for position: Int64) -> CMTime { CMTime(value: position, timescale: 48000) }
}
final class AudioFrame {
    var position: Int64 = 48000
    var duration: Int64 = 1024
    var numberOfSamples = 1024
    let timebase = Timebase()
}
final class AudioSink {
    var time = CMTime.zero
    var rate = 1.0
    func setAudio(time: CMTime, rate: Double) { self.time = time; self.rate = rate }
}
final class AudioEnginePlayer {
    let timingLock = NSLock()
    var audioTiming = (latency: 0.0, rate: 1.0)
    var renderTiming = (latency: 0.0, rate: 1.0)
    var sourceNode: AudioSource? = AudioSource()
    var currentRender: AudioFrame? = AudioFrame()
    var currentRenderReadOffset = 512
    var renderSource: AudioSink? = AudioSink()
}
"""

tests = r"""
import Foundation
import Combine
import CoreMedia
import AudioToolbox

func near(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-8) {
    precondition(abs(actual - expected) < tolerance, "\(actual) != \(expected)")
}
func drainMainQueue() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
func sameFrames(_ actual: [Double], _ expected: [Double]) -> Bool {
    actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 }
}

func replayDisplayCadence(_ pts: [Double], displayFPS: Double, rate: Double = 1,
                          audioBlock: Double = 512.0 / 48000, silent: Bool = false,
                          delayedTick: Int? = nil) -> [Double] {
    let origin = 1000.0
    TestClock.now = origin
    let source = MEPlayerItem()
    source.isAudioStalled = silent
    source.videoTrack = Track(pts)
    source.startTime = pts[0]
    source.resetVideoClock()
    let view = MetalPlayView()
    view.renderSource = source
    view.configureDisplayLink()
    view.isPaused = false
    if !silent { source.setAudio(time: CMTime(seconds: pts[0], preferredTimescale: 1_000_000_000), rate: rate) }
    view.displayLink!.targetTimestamp = origin
    view.displayLink!.fire()
    let duration = (pts.last! - pts[0]) / rate
    let count = Int(ceil(duration * displayFPS)) + 2
    var expectedIndex = 0
    for n in 1...count {
        // Display deadlines stay fixed while callback delivery varies by 2 ms.
        let target = origin + Double(n) / displayFPS
        let callback = target - 1 / displayFPS + (n % 2 == 0 ? 0.001 : 0.003)
        if let delayedTick = delayedTick, n >= delayedTick && n < delayedTick + 6 { continue }
        if !silent {
            let audioTime = floor((callback - origin) / audioBlock) * audioBlock
            TestClock.now = origin + audioTime
            source.setAudio(time: CMTime(seconds: pts[0] + audioTime * rate, preferredTimescale: 1_000_000_000), rate: rate)
        }
        TestClock.now = callback
        view.displayLink!.targetTimestamp = target
        view.displayLink!.fire()
        if let drawn = view.drawnFrames.last {
            let desired = pts[0] + (target - origin) * rate
            while expectedIndex + 1 < pts.count && pts[expectedIndex + 1] <= desired + 0.000001 {
                expectedIndex += 1
            }
            precondition(abs(drawn - pts[expectedIndex]) < 0.00002,
                         "cadence mismatch: fps=\(displayFPS) block=\(audioBlock) silent=\(silent) rate=\(rate) tick=\(n) drawn=\(drawn) expected=\(pts[expectedIndex]) target=\(target) callback=\(callback)")
        }
    }
    return view.drawnFrames
}

@main struct TimingTests {
    static func main() throws {
        setbuf(stdout, nil)
        var view: MetalPlayView? = MetalPlayView()
        weak let weakView = view
        #if TEST_UIKIT
        view!.configureDisplayLink()
        let link = view!.displayLink!
        precondition(link.mode == .common)
        precondition(link.isPaused)
        view!.isPaused = false
        precondition(!link.isPaused)
        view!.isPaused = true
        precondition(link.isPaused)
        view = nil
        precondition(weakView == nil, "display link retained the view")
        link.fire()
        print("PASS: display-link common mode, pause/resume, weak target lifetime")
        #else
        view!.observeFrameRate()
        drainMainQueue()
        near(view!.timer.intervals.last!, 1.0 / 60)
        for fps: Float in [60000.0 / 1001.0, 24, 120, 0, .nan, .infinity] {
            view!.options.preferredFramesPerSecond = fps
            drainMainQueue()
            let validFPS = fps.isFinite && fps > 0 ? max(Double(fps), 60) : 60
            near(view!.timer.intervals.last!, 1.0 / validFPS)
        }
        let options = view!.options
        let changed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            options.preferredFramesPerSecond = 30
            changed.signal()
        }
        changed.wait()
        drainMainQueue()
        near(view!.timer.intervals.last!, 1.0 / 60)
        view = nil
        precondition(weakView == nil, "frame-rate subscription retained the view")
        print("PASS: fractional intervals, frame-rate changes, main-queue scheduling, subscription lifetime")
        #endif

        let item = MEPlayerItem()
        let track = Track([0, 0.1, 0.2, 0.3, 0.4, 0.5])
        item.videoTrack = track
        item.currentPlaybackTime = 0.35
        near(item.getVideoOutputRender()!.seconds, 0.3)
        near(track.frames.first!.seconds, 0.4)
        precondition(item.getVideoOutputRender() == nil, "future frame was consumed")
        item.currentPlaybackTime = 0.5
        near(item.getVideoOutputRender()!.seconds, 0.5)
        precondition(track.emptyReads == 0, "EOF reported before the final frame was displayed")
        precondition(item.getVideoOutputRender() == nil && track.emptyReads == 1)
        let refilling = Track([0, 0.1, 0.2])
        refilling.refill = true
        item.videoTrack = refilling
        _ = item.getVideoOutputRender()
        precondition(refilling.reads == 3, "decoder refill caused unbounded work")
        item.videoTrack = Track([10, 10.1, 10.2, 10.3])
        item.startTime = 10
        item.currentPlaybackTime = 0.1
        item.options.audioDelay = 0.15
        near(item.getVideoOutputRender()!.seconds, 10.2)
        item.videoTrack = Track([0, 0.1, 0.2, 0.3])
        item.startTime = 0
        item.currentPlaybackTime = 0.1
        item.options.audioDelay = 0
        item.isAudioStalled = true
        item.videoMediaTime = CACurrentMediaTime() - 0.15
        item.videoClockDelay = 0
        near(item.getVideoOutputRender()!.seconds, 0.2)
        item.setVideo(time: CMTime(seconds: 0.2, preferredTimescale: 1000))
        precondition(item.getVideoOutputRender() == nil, "video-only clock jumped after catch-up")
        item.isAudioStalled = false
        item.state = .seeking
        item.setAudio(time: CMTime(seconds: 9, preferredTimescale: 1000))
        near(item.currentPlaybackTime, 0.2)
        print("PASS: overdue-frame catch-up, future frames, EOF, bounded decoder work, video-only and seek clocks")

        for fps in [24.0, 30, 60000.0 / 1001.0, 60, 120] {
            let clock = MEPlayerItem()
            clock.videoTrack = Track((0..<Int(fps * 30)).map { Double($0) / fps })
            var tick = 0.0
            while tick < 29.5 {
                clock.currentPlaybackTime = tick
                if let frame = clock.getVideoOutputRender() {
                    precondition(tick - frame.seconds < 1 / fps + 1e-8)
                }
                tick += tick > 7 && tick < 7.1 ? 0.25 : 0.017
            }
        }
        print("PASS: 30-second clock replays at 24/30/59.94/60/120 fps, including a delayed draw")

        let cadences: [(Double, Double)] = [(24, 60), (25, 50), (30, 60), (30, 60000.0 / 1001),
                                           (30000.0 / 1001, 60000.0 / 1001), (50, 50),
                                           (60000.0 / 1001, 60000.0 / 1001), (60, 60), (120, 120)]
        for (fps, displayFPS) in cadences {
            let pts = (0..<Int(fps * 24)).map { Double($0) / fps }
            for block in [256.0 / 48000, 512.0 / 48000, 1024.0 / 48000] {
                precondition(sameFrames(replayDisplayCadence(pts, displayFPS: displayFPS, audioBlock: block), pts),
                             "frames dropped at \(fps) fps with \(block) second audio blocks")
            }
            precondition(sameFrames(replayDisplayCadence(pts, displayFPS: displayFPS, silent: true), pts),
                         "video-only clock drifted or dropped frames")
        }
        let pixelPTS = (0..<718).map { Double($0) / 30 }
        for rate in [0.5, 1.0, 2.0] {
            precondition(sameFrames(replayDisplayCadence(pixelPTS, displayFPS: 60, rate: rate), pixelPTS))
        }
        let caughtUp = replayDisplayCadence(pixelPTS, displayFPS: 60, delayedTick: 120)
        precondition(caughtUp.count < pixelPTS.count && caughtUp.last == pixelPTS.last)
        print("PASS: display deadlines with callback jitter, 24/25/29.97/30/50/59.94/60/120 fps, audio blocks, muted video, rates, delayed draw")

        TestClock.now = 1000
        let interpolated = MEPlayerItem()
        interpolated.videoTrack = Track((0..<120).map { Double($0) / 60 })
        interpolated.setAudio(time: .zero)
        near(interpolated.getVideoOutputRender(at: 1010)!.seconds, 0.1)
        precondition(interpolated.getVideoOutputRender(at: 1020) == nil, "stalled audio clock ran away")
        interpolated.playbackClockLock.lock()
        interpolated.setAudio(time: CMTime(seconds: 9, preferredTimescale: 60000))
        interpolated.playbackClockLock.unlock()
        near(interpolated.currentPlaybackTime, 0)
        interpolated.state = .seeking
        interpolated.currentPlaybackTime = 1
        interpolated.resetVideoClock()
        near(interpolated.getVideoOutputRender(at: 1030)!.seconds, 1)
        precondition(interpolated.audioClock == nil)
        print("PASS: bounded audio extrapolation, nonblocking clock publication, seek invalidation")

        TestClock.now = 2000
        let tail = MEPlayerItem()
        tail.videoTrack = Track([10, 10.05, 10.1, 10.15])
        tail.setAudio(time: CMTime(seconds: 10, preferredTimescale: 60000))
        tail.isAudioStalled = true
        TestClock.now += 0.05
        let tailFrame = tail.getVideoOutputRender()!
        near(tailFrame.seconds, 10.05)
        tail.setVideo(time: tailFrame.cmtime)
        TestClock.now += 0.05
        near(tail.getVideoOutputRender()!.seconds, 10.1)
        print("PASS: video tail continues from the final audio clock without jumping")

        let backpressure = MetalPlayView()
        backpressure.renderSource = MEPlayerItem()
        backpressure.renderSource!.videoTrack = Track([0, 0.1])
        backpressure.isPaused = false
        backpressure.displayLayer.isReadyForMoreMediaData = false
        backpressure.drawView()
        precondition(backpressure.renderSource!.videoTrack!.reads == 0)
        backpressure.displayLayer.isReadyForMoreMediaData = true
        backpressure.displayLayer.status = .failed
        backpressure.drawView()
        precondition(backpressure.drawnFrames == [0] && backpressure.displayLayer.flushCount == 1)
        print("PASS: display-layer backpressure preserves queued frames and recovers a failed layer")

        let player = KSMEPlayer()
        player.videoOutput.configureDisplayLink()
        let layer = KSPlayerLayer()
        layer.player = player
        player.playerItem.isAudioStalled = true
        player.playerItem.currentPlaybackTime = 10
        player.playerItem.videoTrack = Track((600..<6600).map { Double($0) / 60 })
        player.playbackState = .playing
        player.playOrPause()
        player.videoOutput.drawView()
        near(player.videoOutput.drawnFrames.last!, 10)
        for away in [2.0, 30, 300] {
            player.playbackState = .paused
            player.playOrPause()
            player.playOrPause() // Repeated lifecycle/load notifications must be harmless.
            let time = player.playerItem.currentPlaybackTime
            let queued = player.playerItem.videoTrack!.frameCount
            let drawn = player.videoOutput.drawnFrames.count
            TestClock.now += away
            player.videoOutput.drawView() // An event queued before timer suspension.
            precondition(player.playerItem.videoTrack!.frameCount == queued)
            near(player.playerItem.currentPlaybackTime, time)
            layer.enterForeground()
            precondition(player.videoOutput.drawnFrames.count == drawn + 1)
            near(player.videoOutput.drawnFrames.last!, time)
            precondition(player.videoOutput.isPaused)
            #if TEST_UIKIT
            precondition(player.videoOutput.displayLink!.isPaused)
            #else
            precondition(player.videoOutput.timer.suspensionCount == 1)
            #endif
            precondition(player.playerItem.videoTrack!.frameCount == queued)
            TestClock.now += 10 // Remain paused after returning to the app.
            player.playbackState = .playing
            player.playOrPause()
            near(player.playerItem.videoClockDelay, 0)
            player.videoOutput.drawView()
            near(player.playerItem.currentPlaybackTime, time)
            TestClock.now += 1.0 / 60 + 1e-7 // Just past the frame boundary, avoiding Float64 rounding.
            player.playOrPause() // Must not reset a running clock.
            player.videoOutput.drawView()
            near(player.playerItem.currentPlaybackTime, time + 1.0 / 60)
            #if TEST_UIKIT
            precondition(!player.videoOutput.displayLink!.isPaused)
            #else
            precondition(player.videoOutput.timer.suspensionCount == 0)
            #endif
        }
        print("PASS: repeated background/resume, paused redraw, queued timer events, normal-speed restart")

        player.loadState = .loading
        player.playOrPause()
        TestClock.now += 90
        player.playerItem.videoClockDelay = 90
        let beforeBuffering = player.playerItem.currentPlaybackTime
        player.loadState = .playable
        player.playOrPause()
        player.videoOutput.drawView()
        near(player.playerItem.currentPlaybackTime, beforeBuffering)
        near(player.playerItem.videoClockDelay, 0)
        player.playbackState = .seeking
        player.playOrPause()
        TestClock.now += 20
        player.playerItem.currentPlaybackTime = 50
        player.playerItem.videoTrack = Track([50, 50.1, 50.2])
        player.playbackState = .playing
        player.playOrPause()
        player.videoOutput.drawView()
        near(player.playerItem.currentPlaybackTime, 50)
        player.videoOutput.options.usesDisplayLayer = false
        let flushes = player.videoOutput.displayLayer.flushCount
        layer.enterForeground()
        near(player.videoOutput.drawnFrames.last!, 50)
        precondition(player.videoOutput.displayLayer.flushCount == flushes)
        player.videoOutput.clear()
        let afterClear = player.videoOutput.drawnFrames.count
        layer.enterForeground()
        precondition(player.videoOutput.drawnFrames.count == afterClear, "old media frame restored after clear")
        print("PASS: buffering/seek clock restart, Metal redraw, cleared-frame lifetime")

        let audio = AudioEnginePlayer()
        let rendered = 1 + 512.0 / 48000
        for latency in [0.0, 0.015, 0.176, 0.3] {
            audio.sourceNode!.outputPresentationLatency = latency
            audio.updateOutputLatency()
            for rate in [0.5, 1.0, 2.0] {
                audio.audioTiming.rate = rate
                audio.audioPlayerDidRenderSample(sampleTimestamp: AudioTimeStamp())
                near(audio.renderSource!.time.seconds, rendered - latency * rate)
                near(audio.renderSource!.rate, rate)
            }
        }
        audio.sourceNode!.outputPresentationLatency = .nan
        audio.updateOutputLatency()
        near(audio.audioTiming.latency, 0)
        audio.audioTiming = (latency: 0.1, rate: 1)
        audio.audioPlayerDidRenderSample(sampleTimestamp: AudioTimeStamp())
        audio.timingLock.lock()
        audio.audioTiming.latency = 0.2
        audio.audioPlayerDidRenderSample(sampleTimestamp: AudioTimeStamp())
        near(audio.renderSource!.time.seconds, rendered - 0.1)
        audio.timingLock.unlock()
        audio.audioPlayerDidRenderSample(sampleTimestamp: AudioTimeStamp())
        near(audio.renderSource!.time.seconds, rendered - 0.2)
        audio.currentRender = nil
        audio.audioPlayerDidRenderSample(sampleTimestamp: AudioTimeStamp())
        print("PASS: audio latency/route updates, playback rates, invalid latency, nonblocking clock publication")

        if CommandLine.arguments.count > 1 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let pts = try JSONDecoder().decode([Double].self, from: data)
            let sample = MEPlayerItem()
            sample.videoTrack = Track(pts)
            var tick = 0.0
            var maximumLag = 0.0
            while tick < pts.last! {
                sample.currentPlaybackTime = tick
                if let frame = sample.getVideoOutputRender() {
                    maximumLag = max(maximumLag, tick - frame.seconds)
                }
                tick += tick > 10 && tick < 10.1 ? 0.25 : 0.017
            }
            // A 30 fps frame may be up to 33.33 ms old. The old fixed 18 ms
            // assertion only applied to the 60 fps sample used originally.
            let longestFrame = zip(pts, pts.dropFirst()).map { $1 - $0 }.max()!
            precondition(maximumLag <= longestFrame + 0.000001)
            print("PASS: customer sample PTS replay; maximum video lag \(maximumLag * 1000) ms")
            let displayed = replayDisplayCadence(pts, displayFPS: 60)
            precondition(sameFrames(displayed, pts), "sample lost frames with display callback jitter")
            print("PASS: customer sample display replay: \(displayed.count)/\(pts.count) frames, no repeats or drops")
        }
    }
}
"""

with tempfile.TemporaryDirectory(prefix="ksplayer-timing-") as directory:
    work = Path(directory)
    sources = []
    for name, text in [("Production.swift", production), ("Support.swift", support), ("Tests.swift", tests)]:
        path = work / name
        path.write_text(text)
        sources.append(str(path))
    sample_args = []
    if len(sys.argv) > 1:
        frames = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
            "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", sys.argv[1],
        ]))["frames"]
        timestamps = work / "timestamps.json"
        timestamps.write_text(json.dumps([float(f["best_effort_timestamp_time"]) for f in frames]))
        sample_args.append(str(timestamps))
    for mode, flags in [("display-link", ["-D", "TEST_UIKIT"]), ("mac-timer", [])]:
        executable = work / ("timing-tests-" + mode)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(work / "modules"),
            *flags, *sources, "-o", str(executable),
        ], check=True)
        print("Testing " + mode, flush=True)
        subprocess.run([str(executable), *sample_args], check=True)
