//
//  MetalPlayView.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/11.
//

import AVFoundation
import Combine
import CoreMedia
import MetalKit

final class MetalPlayView: UIView {
    private let render = MetalRender()
    private let view = MTKView(frame: .zero, device: MetalRender.device)
    private var videoInfo: CMVideoFormatDescription?
    private var pixelBuffer: CVPixelBuffer?
    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    #else
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
    private var frameRateCancellable: AnyCancellable?
    #endif
    var options: KSOptions
    weak var renderSource: OutputRenderSourceDelegate?
    #if canImport(UIKit)
    override public class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    #endif
    // AVSampleBufferAudioRenderer AVSampleBufferRenderSynchronizer AVSampleBufferDisplayLayer
    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable force_cast
        layer as! AVSampleBufferDisplayLayer
        // swiftlint:enable force_cast
    }

    init(options: KSOptions) {
        self.options = options
        super.init(frame: .zero)
        #if canImport(UIKit)
        configureDisplayLink()
        #else
        observeFrameRate()
        timer.setEventHandler { [weak self] in
            self?.drawView()
        }
        timer.activate()
        #endif
        #if !canImport(UIKit)
        layer = AVSampleBufferDisplayLayer()
        #endif
        #if os(macOS)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        #endif
        view.framebufferOnly = true
        addSubview(view)
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.topAnchor),
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        isPaused = true
        var controlTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &controlTimebase)
        if let controlTimebase = controlTimebase {
            displayLayer.controlTimebase = controlTimebase
            CMTimebaseSetTime(controlTimebase, time: .zero)
            CMTimebaseSetRate(controlTimebase, rate: 1.0)
        }
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var contentMode: UIViewContentMode {
        didSet {
            view.contentMode = contentMode
            switch contentMode {
            case .scaleToFill:
                displayLayer.videoGravity = .resize
            case .scaleAspectFit, .center:
                displayLayer.videoGravity = .resizeAspect
            case .scaleAspectFill:
                displayLayer.videoGravity = .resizeAspectFill
            default:
                break
            }
        }
    }

    #if canImport(UIKit)
    override func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if options.display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            options.display.touchesMoved(touch: touches.first!)
        }
    }
    #endif
    func toImage() -> UIImage? {
        pixelBuffer?.image().flatMap { UIImage(cgImage: $0) }
    }

    func clear() {
        pixelBuffer = nil
        videoInfo = nil
        if view.isHidden {
            displayLayer.flushAndRemoveImage()
        } else {
            if let drawable = view.currentDrawable, let renderPassDescriptor = view.currentRenderPassDescriptor {
                render.clear(drawable: drawable, renderPassDescriptor: renderPassDescriptor)
            }
        }
    }

    func restoreLastFrame() {
        guard let pixelBuffer = pixelBuffer else { return }
        if options.isUseDisplayLayer() {
            displayLayer.flush()
        }
        draw(pixelBuffer: pixelBuffer)
    }

    #if canImport(UIKit)
    private func configureDisplayLink() {
        // Sample at the display cadence, not the movie's nominal frame rate.
        // A 30 Hz timer can miss a frame's deadline and then discard it on the
        // next tick. The next display timestamp is stable despite callback jitter.
        let target = VideoDisplayLinkTarget { [weak self] link in
            self?.drawView(at: link.targetTimestamp)
        }
        let link = CADisplayLink(target: target, selector: #selector(VideoDisplayLinkTarget.draw(_:)))
        displayLink = link
        link.isPaused = true
        link.add(to: .main, forMode: .common)
    }
    #else
    private func observeFrameRate() {
        frameRateCancellable = options.$preferredFramesPerSecond
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                let fps = value.isFinite && value > 0 ? max(Double(value), 60.0) : 60.0
                // Preserve fractional frame intervals (59.94/60 fps are both below 17 ms).
                self?.timer.schedule(deadline: .now(), repeating: 1.0 / fps)
            }
    }
    #endif

    deinit {
        #if canImport(UIKit)
        displayLink?.invalidate()
        #else
        if isPaused {
            timer.resume()
        }
        timer.cancel()
        #endif
    }
}

extension MetalPlayView {
    private func set(pixelBuffer: CVPixelBuffer) {
        if videoInfo == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoInfo!, imageBuffer: pixelBuffer) {
            let err = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &videoInfo)
            if err != noErr {
                KSLog("Error at CMVideoFormatDescriptionCreateForImageBuffer \(err)")
            }
        }
        guard let videoInfo = videoInfo else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
//        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        // swiftlint:disable line_length
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoInfo, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        // swiftlint:enable line_length
        if let sampleBuffer = sampleBuffer {
            if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary], let dic = attachmentsArray.first {
                dic[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            if displayLayer.isReadyForMoreMediaData {
                displayLayer.enqueue(sampleBuffer)
            }
//            if let controlTimebase = displayLayer.controlTimebase {
//                CMTimebaseSetTime(controlTimebase, time: time)
//            }
        }
    }

    private func drawView(at hostTime: TimeInterval = CACurrentMediaTime()) {
        // A callback already queued at pause must not consume a frame.
        guard !isPaused else { return }
        if options.isUseDisplayLayer() {
            if displayLayer.status == .failed { displayLayer.flush() }
            guard displayLayer.isReadyForMoreMediaData else { return }
        }
        guard let frame = renderSource?.getVideoOutputRender(at: hostTime) else {
            return
        }
        pixelBuffer = frame.corePixelBuffer
        guard let pixelBuffer = pixelBuffer else {
            return
        }
        let cmtime = frame.cmtime
        renderSource?.setVideo(time: cmtime, at: hostTime)
        draw(pixelBuffer: pixelBuffer)
    }

    private func draw(pixelBuffer: CVPixelBuffer) {
        let par = pixelBuffer.size
        let sar = pixelBuffer.aspectRatio
        if options.isUseDisplayLayer() {
            if !view.isHidden {
                view.isHidden = true
                if let drawable = view.currentDrawable, let renderPassDescriptor = view.currentRenderPassDescriptor {
                    render.clear(drawable: drawable, renderPassDescriptor: renderPassDescriptor)
                }
            }
            if let dar = options.customizeDar(sar: sar, par: par) {
                pixelBuffer.aspectRatio = CGSize(width: dar.width, height: dar.height * par.width / par.height)
            }
            set(pixelBuffer: pixelBuffer)
        } else {
            if view.isHidden {
                view.isHidden = false
                displayLayer.flushAndRemoveImage()
            }
            autoreleasepool {
                if options.display == .plane {
                    if let dar = options.customizeDar(sar: sar, par: par) {
                        view.drawableSize = CGSize(width: par.width, height: par.width * dar.height / dar.width)
                    } else {
                        view.drawableSize = CGSize(width: par.width, height: par.height * sar.height / sar.width)
                    }
                } else {
                    view.drawableSize = UIScreen.size
                }
                view.colorPixelFormat = KSOptions.colorPixelFormat(bitDepth: pixelBuffer.bitDepth)
                (view.layer as? CAMetalLayer)?.colorspace = pixelBuffer.colorspace
                guard let drawable = view.currentDrawable else {
                    return
                }
                render.draw(pixelBuffer: pixelBuffer, display: options.display, drawable: drawable)
            }
        }
    }
}

extension MetalPlayView: FrameOutput {
    var isPaused: Bool {
        get {
            view.isPaused
        }
        set {
            if isPaused != newValue {
                view.isPaused = newValue
                #if canImport(UIKit)
                displayLink?.isPaused = newValue
                #else
                newValue ? timer.suspend() : timer.resume()
                #endif
            }
        }
    }

    var drawableSize: CGSize {
        get {
            view.drawableSize
        }
        set {
            view.drawableSize = newValue
        }
    }
}

#if canImport(UIKit)
// CADisplayLink retains its target. The closure captures the view weakly so
// dismissing a player can deinitialize the view and invalidate the display link.
private final class VideoDisplayLinkTarget: NSObject {
    private let callback: (CADisplayLink) -> Void

    init(callback: @escaping (CADisplayLink) -> Void) {
        self.callback = callback
        super.init()
    }

    @objc func draw(_ link: CADisplayLink) {
        callback(link)
    }
}
#endif

#if os(macOS)
import CoreVideo
class CADisplayLink {
    private let displayLink: CVDisplayLink
    private let target: AnyObject
    private let selector: Selector
    private var runloop: RunLoop?
    private var mode = RunLoop.Mode.default
    public var timestamp: TimeInterval {
        var timeStamp = CVTimeStamp()
        if CVDisplayLinkGetCurrentTime(displayLink, &timeStamp) == kCVReturnSuccess, (timeStamp.flags & CVTimeStampFlags.hostTimeValid.rawValue) != 0 {
            return TimeInterval(timeStamp.hostTime / NSEC_PER_SEC)
        }
        return 0
    }

    public var duration: TimeInterval {
        CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
    }

    public var targetTimestamp: TimeInterval {
        duration + timestamp
    }

    public var isPaused: Bool {
        get {
            !CVDisplayLinkIsRunning(displayLink)
        }
        set {
            if newValue {
                CVDisplayLinkStop(displayLink)
            } else {
                CVDisplayLinkStart(displayLink)
            }
        }
    }

    public init(target: NSObject, selector sel: Selector) {
        self.target = target
        selector = sel
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &displayLink)
        self.displayLink = displayLink!
        CVDisplayLinkSetOutputCallback(self.displayLink, { (_, _, _, _, _, userData: UnsafeMutableRawPointer?) -> CVReturn in
            guard let userData = userData else {
                return kCVReturnError
            }
            let `self` = Unmanaged<CADisplayLink>.fromOpaque(userData).takeUnretainedValue()
            self.runloop?.perform(self.selector, target: self.target, argument: self, order: 0, modes: [self.mode])
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(self.displayLink)
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        self.runloop = runloop
        self.mode = mode
    }

    public func invalidate() {
        isPaused = true
        runloop = nil
    }
}
#endif
