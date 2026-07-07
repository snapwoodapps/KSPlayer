//
//  IOSVideoPlayerView.swift
//  Pods
//
//  Created by kintan on 2018/10/31.
//
#if canImport(UIKit) && !os(tvOS) //&& canImport(CallKit)
import AVKit
//import CallKit
import Combine
import CoreServices
import MediaPlayer
import UIKit
open class IOSVideoPlayerView: VideoPlayerView {
    private weak var originalSuperView: UIView?
    private var originalframeConstraints: [NSLayoutConstraint]?
    private var originalFrame = CGRect.zero
    private var originalOrientations: UIInterfaceOrientationMask?
    private weak var fullScreenDelegate: PlayerViewFullScreenDelegate?
    private var isPlayingForCall = false
//    private let callCenter = CXCallObserver()
    private var isVolume = false
    private let pinchGesture = UIPinchGestureRecognizer()
    private let videoZoomPanGesture = UIPanGestureRecognizer()
    private let minimumVideoZoomScale = CGFloat(1.0)
    private let maximumVideoZoomScale = CGFloat(5.0)
    private var videoZoomScale = CGFloat(1.0)
    private var videoZoomOffset = CGPoint.zero
    private var videoZoomPanStartOffset = CGPoint.zero
    private var pinchStartZoomScale = CGFloat(1.0)
    private var pinchStartZoomOffset = CGPoint.zero
    private var pinchStartLocation = CGPoint.zero
    private var wasVideoZoomInteractionActive = false
//    private let volumeView = BrightnessVolume()
    private var cancellable: AnyCancellable?
    public var volumeViewSlider = UXSlider()
    public var backButton = UIButton()
    public var airplayStatusView: UIView = AirplayStatusView()
    public var routeButton = AVRoutePickerView()
    private let routeDetector = AVRouteDetector()
    public var videoZoomInteractionDidChange: ((Bool) -> Void)?
    public private(set) var isVideoZooming = false
    public var isVideoZoomed: Bool { videoZoomScale > minimumVideoZoomScale + 0.01 }
    public var isVideoZoomInteractionActive: Bool { isVideoZooming || isVideoZoomed }
    /// Image view to show video cover
    public var maskImageView = UIImageView()
    public var landscapeButton = UIButton()
    override open var isMaskShow: Bool {
        didSet {
            fullScreenDelegate?.player(isMaskShow: isMaskShow, isFullScreen: landscapeButton.isSelected)
        }
    }
    
    deinit {
        cancellable?.cancel()
        cancellable = nil
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        videoZoomOffset = clampedVideoZoomOffset(videoZoomOffset, scale: videoZoomScale)
        updateVideoZoomTransform(animated: false)
    }

    override open func customizeUIComponents() {
        super.customizeUIComponents()
        playerLayer.clipsToBounds = true
        panGesture.maximumNumberOfTouches = 1
        pinchGesture.addTarget(self, action: #selector(pinchGestureAction(_:)))
        pinchGesture.cancelsTouchesInView = false
        controllerView.addGestureRecognizer(pinchGesture)
        videoZoomPanGesture.addTarget(self, action: #selector(videoZoomPanGestureAction(_:)))
        videoZoomPanGesture.maximumNumberOfTouches = 1
        videoZoomPanGesture.cancelsTouchesInView = false
        videoZoomPanGesture.isEnabled = false
        controllerView.addGestureRecognizer(videoZoomPanGesture)
        if UIDevice.current.userInterfaceIdiom == .phone {
            subtitleLabel.font = .systemFont(ofSize: 14)
        }
        cancellable = srtControl.$srtListCount.sink { [weak self] count in
            guard let self = self, count > 0 else {
                return
            }
            if self.landscapeButton.isSelected || UIDevice.current.userInterfaceIdiom == .pad {
                self.toolBar.srtButton.isHidden = false
            }
        }
        insertSubview(maskImageView, at: 0)
        maskImageView.contentMode = .scaleAspectFit
        toolBar.addArrangedSubview(landscapeButton)
        landscapeButton.tag = PlayerButtonType.landscape.rawValue
        landscapeButton.setImage(KSPlayerManager.image(named: "KSPlayer_fullscreen"), for: .normal)
        landscapeButton.setImage(KSPlayerManager.image(named: "KSPlayer_portialscreen"), for: .selected)
        landscapeButton.addTarget(self, action: #selector(onButtonPressed(_:)), for: .touchUpInside)
        backButton.tag = PlayerButtonType.back.rawValue
        backButton.setImage(KSPlayerManager.image(named: "KSPlayer_back"), for: .normal)
        backButton.addTarget(self, action: #selector(onButtonPressed(_:)), for: .touchUpInside)
        navigationBar.insertArrangedSubview(backButton, at: 0)
        routeButton.isHidden = true
        navigationBar.addArrangedSubview(routeButton)
        addSubview(airplayStatusView)
//        volumeView.move(to: self)
//        let tmp = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 0, height: 0))
//        if let first = (tmp.subviews.first { $0 is UISlider }) as? UISlider {
//            volumeViewSlider = first
//        }
        routeButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.translatesAutoresizingMaskIntoConstraints = false
        landscapeButton.translatesAutoresizingMaskIntoConstraints = false
        maskImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            maskImageView.topAnchor.constraint(equalTo: topAnchor),
            maskImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            maskImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            maskImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 25),
            routeButton.widthAnchor.constraint(equalToConstant: 25),
            landscapeButton.widthAnchor.constraint(equalToConstant: 30),
            airplayStatusView.centerXAnchor.constraint(equalTo: centerXAnchor),
            airplayStatusView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addNotification()
    }

    override open func resetPlayer() {
        super.resetPlayer()
        resetVideoZoom(animated: false)
        maskImageView.alpha = 1
        maskImageView.image = nil
        panGesture.isEnabled = false
        routeButton.isHidden = !routeDetector.multipleRoutesDetected
    }

    override open func onButtonPressed(type: PlayerButtonType, button: UIButton) {
        if type == .back, viewController is PlayerFullScreenViewController {
            updateUI(isFullScreen: false)
            return
        }
        super.onButtonPressed(type: type, button: button)
        if type == .lock {
            button.isSelected.toggle()
            isMaskShow = !button.isSelected
            button.alpha = 1.0
        } else if type == .landscape {
            updateUI(isFullScreen: !landscapeButton.isSelected)
        }
    }

    open func updateUI(isFullScreen: Bool) {
        guard let viewController = viewController else {
            return
        }
        landscapeButton.isSelected = isFullScreen
        let isHorizonal = playerLayer.player?.naturalSize.isHorizonal ?? true
        viewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = !isFullScreen
        if isFullScreen {
            if viewController is PlayerFullScreenViewController {
                return
            }
            originalSuperView = superview
            originalframeConstraints = frameConstraints
            originalFrame = frame
            originalOrientations = viewController.supportedInterfaceOrientations
            let fullVC = PlayerFullScreenViewController(isHorizonal: isHorizonal)
            fullScreenDelegate = fullVC
            fullVC.view.addSubview(self)
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: fullVC.view.readableTopAnchor),
                leadingAnchor.constraint(equalTo: fullVC.view.leadingAnchor),
                trailingAnchor.constraint(equalTo: fullVC.view.trailingAnchor),
                bottomAnchor.constraint(equalTo: fullVC.view.bottomAnchor),
            ])
            fullVC.modalPresentationStyle = .fullScreen
            fullVC.modalPresentationCapturesStatusBarAppearance = true
            fullVC.transitioningDelegate = self
            viewController.present(fullVC, animated: true) {
                KSPlayerManager.supportedInterfaceOrientations = fullVC.supportedInterfaceOrientations
            }
        } else {
            guard viewController is PlayerFullScreenViewController else {
                return
            }
            let presentingVC = viewController.presentingViewController ?? viewController
            KSPlayerManager.supportedInterfaceOrientations = .portrait
            presentingVC.dismiss(animated: true) {
                self.originalSuperView?.addSubview(self)
                if let constraints = self.originalframeConstraints, constraints.count > 0 {
                    NSLayoutConstraint.activate(constraints)
                } else {
                    self.translatesAutoresizingMaskIntoConstraints = true
                    self.frame = self.originalFrame
                }
                if let originalOrientations = self.originalOrientations {
                    KSPlayerManager.supportedInterfaceOrientations = originalOrientations
                }
            }
        }
        let isLandscape = isFullScreen && isHorizonal
        updateUI(isLandscape: isLandscape)
    }

    open func updateUI(isLandscape: Bool) {
        if isLandscape {
            topMaskView.isHidden = KSPlayerManager.topBarShowInCase == .none
        } else {
            topMaskView.isHidden = KSPlayerManager.topBarShowInCase != .always
        }
        toolBar.playbackRateButton.isHidden = false
        toolBar.srtButton.isHidden = srtControl.srtListCount == 0
        srtControl.view.isHidden = true
        if UIDevice.current.userInterfaceIdiom == .phone {
            if isLandscape {
                landscapeButton.isHidden = true
                toolBar.srtButton.isHidden = srtControl.srtListCount == 0
            } else {
                toolBar.srtButton.isHidden = true
                if let image = maskImageView.image {
                    landscapeButton.isHidden = image.size.width < image.size.height
                } else {
                    landscapeButton.isHidden = false
                }
            }
            toolBar.playbackRateButton.isHidden = !isLandscape
        } else {
            landscapeButton.isHidden = true
        }
        lockButton.isHidden = !isLandscape
        judgePanGesture()
    }

    override open func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        if state == .readyToPlay {
            updateVideoZoomTransform(animated: false)
            UIView.animate(withDuration: 0.3) {
                self.maskImageView.alpha = 0.0
            }
        }
        judgePanGesture()
    }

    override open func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        airplayStatusView.isHidden = !(layer.player?.isExternalPlaybackActive ?? false)
        super.player(layer: layer, currentTime: currentTime, totalTime: totalTime)
    }

    override open func set(resource: KSPlayerResource, definitionIndex: Int = 0, isSetUrl: Bool = true) {
        resetVideoZoom(animated: false)
        super.set(resource: resource, definitionIndex: definitionIndex, isSetUrl: isSetUrl)
        maskImageView.image(url: resource.cover)
    }

    override open func change(definitionIndex: Int) {
        playerLayer.player?.thumbnailImageAtCurrentTime { [weak self] image in
            if let self = self, let image = image {
                DispatchQueue.main.async { [weak self] in
                    if let self = self {
                        self.maskImageView.image = image
                        self.maskImageView.alpha = 1
                    }
                }
            }
        }
        super.change(definitionIndex: definitionIndex)
    }

    override open func panGestureBegan(location point: CGPoint, direction: KSPanDirection) {
        if direction == .vertical {
            if point.x > bounds.size.width / 2 {
                isVolume = true
                tmpPanValue = volumeViewSlider.value
            } else {
                isVolume = false
            }
        } else {
            super.panGestureBegan(location: point, direction: direction)
        }
    }

    override open func panGestureChanged(velocity point: CGPoint, direction: KSPanDirection) {
        if direction == .vertical {
            if isVolume {
                if KSPlayerManager.enableVolumeGestures {
                    tmpPanValue += panValue(velocity: point, direction: direction, currentTime: Float(toolBar.currentTime), totalTime: Float(totalTime))
                    tmpPanValue = max(min(tmpPanValue, 1), 0)
                    volumeViewSlider.value = tmpPanValue
                }
            } else if KSPlayerManager.enableBrightnessGestures {
                UIScreen.main.brightness += CGFloat(panValue(velocity: point, direction: direction, currentTime: Float(toolBar.currentTime), totalTime: Float(totalTime)))
            }
        } else {
            super.panGestureChanged(velocity: point, direction: direction)
        }
    }
}

//extension IOSVideoPlayerView: CXCallObserverDelegate {
//    public func callObserver(_: CXCallObserver, callChanged call: CXCall) {
//        if call.hasConnected || call.isOutgoing {
//            isPlayingForCall = toolBar.playButton.isSelected
//            if isPlayingForCall {
//                pause()
//            }
//        } else if call.hasEnded {
//            if isPlayingForCall {
//                play()
//            }
//        }
//    }
//}

extension IOSVideoPlayerView: UIViewControllerTransitioningDelegate {
    public func animationController(forPresented _: UIViewController, presenting _: UIViewController, source _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if let originalSuperView = originalSuperView, let animationView = playerLayer.player?.view {
            return PlayerTransitionAnimator(containerView: originalSuperView, animationView: animationView)
        }
        return nil
    }

    public func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        if let originalSuperView = originalSuperView, let animationView = playerLayer.player?.view {
            return PlayerTransitionAnimator(containerView: originalSuperView, animationView: animationView, isDismiss: true)
        } else {
            return nil
        }
    }
}

// MARK: - private functions

extension IOSVideoPlayerView {
    @objc private func pinchGestureAction(_ pinch: UIPinchGestureRecognizer) {
        guard !isLock, playerLayer.player?.view != nil else {
            return
        }
        switch pinch.state {
        case .began:
            isVideoZooming = true
            pinchStartZoomScale = videoZoomScale
            pinchStartZoomOffset = videoZoomOffset
            pinchStartLocation = pinch.location(in: playerLayer)
            notifyVideoZoomInteractionIfNeeded()
        case .changed:
            let scale = clampedVideoZoomScale(pinchStartZoomScale * pinch.scale)
            let offset = videoZoomOffset(for: scale, location: pinch.location(in: playerLayer))
            setVideoZoom(scale: scale, offset: offset, animated: false)
        case .ended, .cancelled, .failed:
            isVideoZooming = false
            if videoZoomScale <= minimumVideoZoomScale + 0.01 {
                resetVideoZoom(animated: true)
            } else {
                setVideoZoom(scale: videoZoomScale, offset: videoZoomOffset, animated: true)
            }
        default:
            break
        }
    }

    @objc private func videoZoomPanGestureAction(_ pan: UIPanGestureRecognizer) {
        guard isVideoZoomed, !isLock, playerLayer.player?.view != nil else {
            return
        }
        switch pan.state {
        case .began:
            isVideoZooming = true
            videoZoomPanStartOffset = videoZoomOffset
            notifyVideoZoomInteractionIfNeeded()
        case .changed:
            let translation = pan.translation(in: playerLayer)
            let offset = CGPoint(
                x: videoZoomPanStartOffset.x + translation.x,
                y: videoZoomPanStartOffset.y + translation.y
            )
            setVideoZoom(scale: videoZoomScale, offset: offset, animated: false)
        case .ended, .cancelled, .failed:
            isVideoZooming = false
            setVideoZoom(scale: videoZoomScale, offset: videoZoomOffset, animated: true)
        default:
            break
        }
    }

    private func resetVideoZoom(animated: Bool) {
        isVideoZooming = false
        setVideoZoom(scale: minimumVideoZoomScale, offset: .zero, animated: animated)
    }

    private func setVideoZoom(scale: CGFloat, offset: CGPoint, animated: Bool) {
        videoZoomScale = clampedVideoZoomScale(scale)
        videoZoomOffset = clampedVideoZoomOffset(offset, scale: videoZoomScale)
        updateVideoZoomTransform(animated: animated)
        notifyVideoZoomInteractionIfNeeded()
    }

    private func updateVideoZoomTransform(animated: Bool) {
        guard let videoView = playerLayer.player?.view else {
            return
        }
        let transform: CGAffineTransform
        if videoZoomScale <= minimumVideoZoomScale + 0.01 {
            transform = .identity
        } else {
            transform = CGAffineTransform(a: videoZoomScale, b: 0, c: 0, d: videoZoomScale, tx: videoZoomOffset.x, ty: videoZoomOffset.y)
        }
        let animations = {
            videoView.transform = transform
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: animations)
        } else {
            animations()
        }
    }

    private func videoZoomOffset(for scale: CGFloat, location: CGPoint) -> CGPoint {
        let startScale = max(pinchStartZoomScale, minimumVideoZoomScale)
        let ratio = scale / startScale
        let center = CGPoint(x: playerLayer.bounds.midX, y: playerLayer.bounds.midY)
        let startVector = CGPoint(x: pinchStartLocation.x - center.x, y: pinchStartLocation.y - center.y)
        let locationDelta = CGPoint(x: location.x - pinchStartLocation.x, y: location.y - pinchStartLocation.y)
        let offset = CGPoint(
            x: pinchStartZoomOffset.x * ratio + startVector.x * (1 - ratio) + locationDelta.x,
            y: pinchStartZoomOffset.y * ratio + startVector.y * (1 - ratio) + locationDelta.y
        )
        return clampedVideoZoomOffset(offset, scale: scale)
    }

    private func clampedVideoZoomScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else {
            return minimumVideoZoomScale
        }
        return min(max(scale, minimumVideoZoomScale), maximumVideoZoomScale)
    }

    private func clampedVideoZoomOffset(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        guard scale > minimumVideoZoomScale else {
            return .zero
        }
        let maxX = max(playerLayer.bounds.width * (scale - 1) / 2, 0)
        let maxY = max(playerLayer.bounds.height * (scale - 1) / 2, 0)
        return CGPoint(
            x: min(max(offset.x, -maxX), maxX),
            y: min(max(offset.y, -maxY), maxY)
        )
    }

    private func notifyVideoZoomInteractionIfNeeded() {
        let isActive = isVideoZoomInteractionActive
        guard isActive != wasVideoZoomInteractionActive else {
            return
        }
        wasVideoZoomInteractionActive = isActive
        updateVideoZoomGestureAvailability(isActive: isActive)
        videoZoomInteractionDidChange?(isActive)
    }

    private func updateVideoZoomGestureAvailability(isActive: Bool) {
        videoZoomPanGesture.isEnabled = isActive
        if isActive {
            panGesture.isEnabled = false
        } else {
            judgePanGesture()
        }
    }

    private func addNotification() {
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIApplication.didChangeStatusBarOrientationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routesAvailableDidChange), name: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: nil)
//        callCenter.setDelegate(self, queue: DispatchQueue.main)
    }

    @objc private func routesAvailableDidChange(notification _: Notification) {
        routeButton.isHidden = !routeDetector.multipleRoutesDetected
    }

    @objc private func orientationChanged(notification _: Notification) {
        guard let isHorizonal = playerLayer.player?.naturalSize.isHorizonal, isHorizonal else {
            return
        }
        updateUI(isFullScreen: UIApplication.isLandscape)
    }

    open func judgePanGesture() {
        if isVideoZoomInteractionActive {
            videoZoomPanGesture.isEnabled = true
            panGesture.isEnabled = false
            return
        }
        if landscapeButton.isSelected || UIDevice.current.userInterfaceIdiom == .pad {
            panGesture.isEnabled = isPlayed && !replayButton.isSelected
        } else {
            panGesture.isEnabled = toolBar.playButton.isSelected
        }
    }
}

public class AirplayStatusView: UIView {
    override public init(frame: CGRect) {
        super.init(frame: frame)
        let airplayicon = UIImageView(image: KSPlayerManager.image(named: "airplayicon_play"))
        addSubview(airplayicon)
        let airplaymessage = UILabel()
        airplaymessage.backgroundColor = .clear
        airplaymessage.textColor = .white
        airplaymessage.font = .systemFont(ofSize: 14)
        airplaymessage.text = NSLocalizedString("AirPlay 投放中", comment: "")
        airplaymessage.textAlignment = .center
        addSubview(airplaymessage)
        translatesAutoresizingMaskIntoConstraints = false
        airplayicon.translatesAutoresizingMaskIntoConstraints = false
        airplaymessage.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 100),
            heightAnchor.constraint(equalToConstant: 115),
            airplayicon.topAnchor.constraint(equalTo: topAnchor),
            airplayicon.centerXAnchor.constraint(equalTo: centerXAnchor),
            airplayicon.widthAnchor.constraint(equalToConstant: 100),
            airplayicon.heightAnchor.constraint(equalToConstant: 100),
            airplaymessage.bottomAnchor.constraint(equalTo: bottomAnchor),
            airplaymessage.leadingAnchor.constraint(equalTo: leadingAnchor),
            airplaymessage.trailingAnchor.constraint(equalTo: trailingAnchor),
            airplaymessage.heightAnchor.constraint(equalToConstant: 15),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

public extension KSPlayerManager {
    /// func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask
    static var supportedInterfaceOrientations = UIInterfaceOrientationMask.portrait
}

extension UIApplication {
    static var isLandscape: Bool {
        UIApplication.shared.windows.first?.windowScene?.interfaceOrientation.isLandscape ?? false
    }
}

// MARK: - menu

extension IOSVideoPlayerView {
    override open var canBecomeFirstResponder: Bool {
        true
    }

    override open func canPerformAction(_ action: Selector, withSender _: Any?) -> Bool {
        if action == #selector(IOSVideoPlayerView.openFileAction) {
            return true
        }
        return true
    }

    @objc fileprivate func openFileAction(_: AnyObject) {
        let documentPicker = UIDocumentPickerViewController(documentTypes: [kUTTypeAudio, kUTTypeMovie, kUTTypePlainText] as [String], in: .open)
        documentPicker.delegate = self
        viewController?.present(documentPicker, animated: true, completion: nil)
    }
}

extension IOSVideoPlayerView: UIDocumentPickerDelegate {
    public func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = urls.first {
            if url.isMovie || url.isAudio {
                set(url: url, options: KSOptions())
            } else {
                resource?.subtitle = KSURLSubtitle(url: url)
            }
        }
    }
}

#endif

#if os(iOS)
public class MenuController {
    public init(with builder: UIMenuBuilder) {
        builder.remove(menu: .format)
        builder.insertChild(MenuController.openFileMenu(), atStartOfMenu: .file)
//        builder.insertChild(MenuController.openURLMenu(), atStartOfMenu: .file)
//        builder.insertChild(MenuController.navigationMenu(), atStartOfMenu: .file)
    }

    class func openFileMenu() -> UIMenu {
        let openCommand = UIKeyCommand(input: "O", modifierFlags: .command, action: #selector(IOSVideoPlayerView.openFileAction(_:)))
        openCommand.title = NSLocalizedString("Open File", comment: "")
        let openMenu = UIMenu(title: "",
                              image: nil,
                              identifier: UIMenu.Identifier("com.example.apple-samplecode.menus.openFileMenu"),
                              options: .displayInline,
                              children: [openCommand])
        return openMenu
    }

//    class func openURLMenu() -> UIMenu {
//        let openCommand = UIKeyCommand(input: "O", modifierFlags: [.command, .shift], action: #selector(IOSVideoPlayerView.openURLAction(_:)))
//        openCommand.title = NSLocalizedString("Open URL", comment: "")
//        let openMenu = UIMenu(title: "",
//                              image: nil,
//                              identifier: UIMenu.Identifier("com.example.apple-samplecode.menus.openURLMenu"),
//                              options: .displayInline,
//                              children: [openCommand])
//        return openMenu
//    }
//    class func navigationMenu() -> UIMenu {
//        let arrowKeyChildrenCommands = Arrows.allCases.map { arrow in
//            UIKeyCommand(title: arrow.localizedString(),
//                         image: nil,
//                         action: #selector(IOSVideoPlayerView.navigationMenuAction(_:)),
//                         input: arrow.command,
//                         modifierFlags: .command)
//        }
//        return UIMenu(title: NSLocalizedString("NavigationTitle", comment: ""),
//                      image: nil,
//                      identifier: UIMenu.Identifier("com.example.apple-samplecode.menus.navigationMenu"),
//                      options: [],
//                      children: arrowKeyChildrenCommands)
//    }

    enum Arrows: String, CaseIterable {
        case rightArrow
        case leftArrow
        case upArrow
        case downArrow
        func localizedString() -> String {
            NSLocalizedString("\(rawValue)", comment: "")
        }

        var command: String {
            switch self {
            case .rightArrow:
                return UIKeyCommand.inputRightArrow
            case .leftArrow:
                return UIKeyCommand.inputLeftArrow
            case .upArrow:
                return UIKeyCommand.inputUpArrow
            case .downArrow:
                return UIKeyCommand.inputDownArrow
            }
        }
    }
}
#endif
