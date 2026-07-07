//
//  VideoPlayerView.swift
//  Pods
//
//  Created by kintan on 16/4/29.
//
//
import AVKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import MediaPlayer

/// internal enum to check the pan direction
public enum KSPanDirection {
    case horizontal
    case vertical
}

public protocol LoadingIndector {
    func startAnimating()
    func stopAnimating()
}

#if canImport(UIKit)
extension UIActivityIndicatorView: LoadingIndector {}
#endif

open class VideoPlayerView: PlayerView {
    private let skipBackwardInterval = TimeInterval(15)
    private let skipForwardInterval = TimeInterval(30)
    private let centerControlButtonSize = CGFloat(64)
    private let skipControlButtonSize = CGFloat(58)
    private let centerControlSpacing = CGFloat(30)
    private let timelineThumbDiameter = CGFloat(20)
    private let highlightedTimelineThumbDiameter = CGFloat(26)
    private var delayItem: DispatchWorkItem?
    /// Gesture used to show / hide control view
    public let tapGesture = UITapGestureRecognizer()
    public let doubleTapGesture = UITapGestureRecognizer()
    public let panGesture = UIPanGestureRecognizer()
    /// 滑动方向
    var scrollDirection = KSPanDirection.horizontal
    var tmpPanValue: Float = 0
    private var isSliderSliding = false

    public let bottomMaskView = LayerContainerView()
    public let topMaskView = LayerContainerView()
    // 是否播放过
    private(set) var isPlayed = false
    private var embedSubtitleDataSouce: SubtitleDataSouce? {
        didSet {
            if oldValue !== embedSubtitleDataSouce {
                if let oldValue = oldValue {
                    srtControl.remove(dataSouce: oldValue)
                }
                if let embedSubtitleDataSouce = embedSubtitleDataSouce {
                    srtControl.add(dataSouce: embedSubtitleDataSouce)
                    let infos = srtControl.filterInfos { $0.subtitleDataSouce === embedSubtitleDataSouce }
                    if resource?.definitions[currentDefinition].options.autoSelectEmbedSubtitle ?? false, let first = infos.first {
                        srtControl.view.selectedInfo = first
                    }
                }
            }
        }
    }

    public private(set) var currentDefinition = 0 {
        didSet {
            if let resource = resource {
                toolBar.definitionButton.setTitle(resource.definitions[currentDefinition].definition, for: .normal)
            }
        }
    }

    public private(set) var resource: KSPlayerResource? {
        didSet {
            if let resource = resource, oldValue !== resource {
                srtControl.searchSubtitle(name: resource.name)
                subtitleBackView.isHidden = true
                subtitleBackView.image = nil
                subtitleLabel.attributedText = nil
                titleLabel.text = resource.name
                toolBar.definitionButton.isHidden = resource.definitions.count < 2
                MPNowPlayingInfoCenter.default().nowPlayingInfo = resource.nowPlayingInfo?.nowPlayingInfo
            }
        }
    }

    public let contentOverlayView = UIView()
    public let controllerView = UIView()
    public var navigationBar = UIStackView()
    public var titleLabel = UILabel()
    public var subtitleLabel = UILabel()
    public var subtitleBackView = UIImageView()
    private var subtitleEndTime = TimeInterval(0)
    /// Activty Indector for loading
    public var loadingIndector: UIView & LoadingIndector = UIActivityIndicatorView(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    public var seekToView: UIView & SeekViewProtocol = SeekView()
    public var replayButton = UIButton()
    public var skipBackwardButton = UIButton()
    public var skipForwardButton = UIButton()
    public var lockButton = UIButton()
    public let srtControl = KSSubtitleController()
    public var isLock: Bool { lockButton.isSelected }
    open var isMaskShow = false {
        didSet {
            let alpha: CGFloat = isMaskShow && !isLock ? 1.0 : 0.0
            UIView.animate(withDuration: 0.3) { [weak self] in
                guard let self else { return }
                self.updateCenterPlaybackButton()
                self.updateCenterSeekControls()
                self.updateMuteButton()
                self.lockButton.alpha = self.isMaskShow ? 1.0 : 0.0
                self.topMaskView.alpha = alpha
                self.bottomMaskView.alpha = alpha
                self.delegate?.playerController(maskShow: self.isMaskShow)
                self.layoutIfNeeded()
            }
            if isMaskShow {
                autoFadeOutViewWithAnimation()
            }
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupUIComponents()
    }

    // MARK: - Action Response

    override open func onButtonPressed(type: PlayerButtonType, button: UIButton) {
        autoFadeOutViewWithAnimation()
        super.onButtonPressed(type: type, button: button)
        if type == .srt {
            srtControl.view.isHidden = false
            isMaskShow = false
        } else if type == .rate {
            changePlaybackRate(button: button)
        } else if type == .definition {
            guard let resource = resource, resource.definitions.count > 1 else { return }
            let alertController = UIAlertController(title: NSLocalizedString("select video quality", comment: ""), message: nil, preferredStyle: preferredStyle())
            for (index, definition) in resource.definitions.enumerated() {
                let action = UIAlertAction(title: definition.definition, style: .default) { [weak self] _ in
                    guard let self = self, index != self.currentDefinition else { return }
                    self.change(definitionIndex: index)
                }
                action.setValue(index == currentDefinition, forKey: "checked")
                alertController.addAction(action)
            }
            alertController.addAction(UIAlertAction(title: NSLocalizedString("cancel", comment: ""), style: .cancel, handler: nil))
            viewController?.present(alertController, animated: true, completion: nil)
        } else if type == .pictureInPicture {
            if #available(tvOS 14.0, *) {
                guard let pipController = playerLayer.player?.pipController else {
                    return
                }
                if pipController.isPictureInPictureActive {
                    pipController.stopPictureInPicture()
                    button.isSelected = false
                } else {
                    pipController.startPictureInPicture()
                    button.isSelected = true
                }
            }
        } else if type == .skipBackward {
            seekRelative(by: -skipBackwardInterval)
        } else if type == .skipForward {
            seekRelative(by: skipForwardInterval)
        } else if type == .mute {
            guard let player = playerLayer.player else { return }
            player.isMuted.toggle()
            updateMuteButton()
        } else if type == .audioSwitch || type == .videoSwitch {
            guard let tracks = playerLayer.player?.tracks(mediaType: type == .audioSwitch ? .audio : .video) else {
                return
            }
            let alertController = UIAlertController(title: NSLocalizedString(type == .audioSwitch ? "switch audio" : "switch video", comment: ""), message: nil, preferredStyle: preferredStyle())
            for track in tracks {
                let isEnabled = track.isEnabled
                var title = track.name
                if type == .videoSwitch {
                    title += " \(track.naturalSize.width)x\(track.naturalSize.height)"
                }
                let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                    guard let self = self, !isEnabled else { return }
                    self.playerLayer.player?.select(track: track)
                }
                action.setValue(isEnabled, forKey: "checked")
                alertController.addAction(action)
            }
            alertController.addAction(UIAlertAction(title: NSLocalizedString("cancel", comment: ""), style: .cancel, handler: nil))
            viewController?.present(alertController, animated: true, completion: nil)
        }
    }

    open func changePlaybackRate(button: UIButton) {
        let alertController = UIAlertController(title: NSLocalizedString("select speed", comment: ""), message: nil, preferredStyle: preferredStyle())
        [0.75, 1.0, 1.25, 1.5, 2.0].forEach { rate in
            let title = "\(rate)X"
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self = self else { return }
                button.setTitle(title, for: .normal)
                self.playerLayer.player?.playbackRate = Float(rate)
            }
            action.setValue(title == button.title, forKey: "checked")
            alertController.addAction(action)
        }
        alertController.addAction(UIAlertAction(title: NSLocalizedString("cancel", comment: ""), style: .cancel, handler: nil))
        viewController?.present(alertController, animated: true, completion: nil)
    }

    open func setupUIComponents() {
        addSubview(playerLayer)
        backgroundColor = .black
        addSubview(contentOverlayView)
        addSubview(controllerView)
        #if os(macOS)
        topMaskView.gradientLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.5).cgColor]
        #else
        topMaskView.gradientLayer.colors = [UIColor.black.withAlphaComponent(0.5).cgColor, UIColor.clear.cgColor]
        #endif
        bottomMaskView.gradientLayer.colors = topMaskView.gradientLayer.colors
        topMaskView.gradientLayer.startPoint = .zero
        topMaskView.gradientLayer.endPoint = CGPoint(x: 0, y: 1)
        bottomMaskView.gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        bottomMaskView.gradientLayer.endPoint = .zero

        loadingIndector.isHidden = true
        controllerView.addSubview(loadingIndector)
        // Top views
        topMaskView.addSubview(navigationBar)
        navigationBar.addArrangedSubview(titleLabel)
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16)
        // Bottom views
        bottomMaskView.addSubview(toolBar)
        toolBar.timeSlider.delegate = self
        controllerView.addSubview(seekToView)
        controllerView.addSubview(replayButton)
        replayButton.cornerRadius = 32
        replayButton.titleFont = .systemFont(ofSize: 16)
        replayButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        replayButton.tintColor = .white
        replayButton.setImage(KSPlayerManager.image(named: "KSPlayer_play"), for: .normal)
        replayButton.setImage(KSPlayerManager.image(named: "KSPlayer_replay"), for: .selected)
        replayButton.addTarget(self, action: #selector(onButtonPressed(_:)), for: .primaryActionTriggered)
        replayButton.tag = PlayerButtonType.play.rawValue
        configureCenterControlButton(skipBackwardButton, type: .skipBackward, systemImageName: "gobackward.15", fallbackTitle: "15")
        configureCenterControlButton(skipForwardButton, type: .skipForward, systemImageName: "goforward.30", fallbackTitle: "30")
        skipBackwardButton.isHidden = true
        skipForwardButton.isHidden = true
        controllerView.addSubview(skipBackwardButton)
        controllerView.addSubview(skipForwardButton)
        lockButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        lockButton.cornerRadius = 32
        lockButton.setImage(KSPlayerManager.image(named: "KSPlayer_unlocking"), for: .normal)
        lockButton.setImage(KSPlayerManager.image(named: "KSPlayer_autoRotationLock"), for: .selected)
        lockButton.tag = PlayerButtonType.lock.rawValue
        lockButton.addTarget(self, action: #selector(onButtonPressed(_:)), for: .primaryActionTriggered)
        lockButton.isHidden = true
        controllerView.addSubview(lockButton)
        controllerView.addSubview(topMaskView)
        controllerView.addSubview(bottomMaskView)
        addConstraint()
        topMaskView.alpha = 0.0
        bottomMaskView.alpha = 0.0
        replayButton.alpha = 0.0
        skipBackwardButton.alpha = 0.0
        skipForwardButton.alpha = 0.0
        lockButton.alpha = 0.0
        customizeUIComponents()
        setupSrtControl()
        layoutIfNeeded()
    }

    /// Add Customize functions here
    open func customizeUIComponents() {
        tapGesture.addTarget(self, action: #selector(tapGestureAction(_:)))
        tapGesture.numberOfTapsRequired = 1
        controllerView.addGestureRecognizer(tapGesture)
        panGesture.addTarget(self, action: #selector(panGestureAction(_:)))
        controllerView.addGestureRecognizer(panGesture)
        panGesture.isEnabled = false
        doubleTapGesture.addTarget(self, action: #selector(doubleTapGestureAction))
        doubleTapGesture.numberOfTapsRequired = 2
        tapGesture.require(toFail: doubleTapGesture)
        controllerView.addGestureRecognizer(doubleTapGesture)
    }

    override open func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        updateSeekAvailability(for: layer.player)
        updateMuteButton()
        guard !isSliderSliding else { return }
        super.player(layer: layer, currentTime: currentTime, totalTime: totalTime)
        if let subtitle = resource?.subtitle {
            showSubtile(from: subtitle, at: currentTime)
            subtitleBackView.isHidden = false
        }
    }

    override open func player(layer: KSPlayerLayer, state: KSPlayerState) {
        super.player(layer: layer, state: state)
        switch state {
        case .readyToPlay:
            updateSeekAvailability(for: layer.player)
            embedSubtitleDataSouce = layer.player?.subtitleDataSouce
            toolBar.videoSwitchButton.isHidden = layer.player?.tracks(mediaType: .video).count ?? 1 < 2
            toolBar.audioSwitchButton.isHidden = layer.player?.tracks(mediaType: .audio).count ?? 1 < 2
        case .buffering:
            isPlayed = true
            replayButton.isHidden = false
            showLoader()
        case .bufferFinished:
            isPlayed = true
            replayButton.isHidden = false
            hideLoader()
            autoFadeOutViewWithAnimation()
        case .paused, .playedToTheEnd, .error:
            hideLoader()
            replayButton.isHidden = false
            seekToView.isHidden = true
            delayItem?.cancel()
            isMaskShow = true
            if state == .playedToTheEnd {
                replayButton.isSelected = true
            }
        default:
            break
        }
        updateCenterPlaybackButton()
        updateMuteButton()
        updateCenterSeekControls()
    }

    override open func resetPlayer() {
        super.resetPlayer()
        delayItem = nil
        resource = nil
        toolBar.reset()
        isMaskShow = false
        hideLoader()
        replayButton.isHidden = false
        updateCenterPlaybackButton()
        skipBackwardButton.isHidden = true
        skipForwardButton.isHidden = true
        seekToView.isHidden = true
        isPlayed = false
        embedSubtitleDataSouce = nil
        lockButton.isSelected = false
        srtControl.selectWithFilePath = nil
    }

    // MARK: - KSSliderDelegate

    override open func slider(value: Double, event: ControlEvents) {
        if event == .valueChanged {
            delayItem?.cancel()
        } else if event == .touchUpInside {
            autoFadeOutViewWithAnimation()
        }
        super.slider(value: value, event: event)
        if event == .touchDown {
            isSliderSliding = true
        } else if event == .touchUpInside {
            isSliderSliding = false
        }
    }

    open func change(definitionIndex: Int) {
        guard let resource = resource else { return }
        var shouldSeekTo = 0.0
        if playerLayer.state != .playedToTheEnd, let currentTime = playerLayer.player?.currentPlaybackTime {
            shouldSeekTo = currentTime
        }
        currentDefinition = definitionIndex >= resource.definitions.count ? resource.definitions.count - 1 : definitionIndex
        let asset = resource.definitions[currentDefinition]
        super.set(url: asset.url, options: asset.options)
        if shouldSeekTo > 0 {
            seek(time: shouldSeekTo)
        }
    }

    open func set(resource: KSPlayerResource, definitionIndex: Int = 0, isSetUrl: Bool = true) {
        self.resource = resource
        currentDefinition = definitionIndex >= resource.definitions.count ? resource.definitions.count - 1 : definitionIndex
        if isSetUrl {
            let asset = resource.definitions[currentDefinition]
            super.set(url: asset.url, options: asset.options)
        }
    }

    override open func set(url: URL, options: KSOptions) {
        set(resource: KSPlayerResource(url: url, options: options))
    }

    @objc open func doubleTapGestureAction() {
        toolBar.playButton.sendActions(for: .primaryActionTriggered)
        isMaskShow = true
    }

    @objc open func tapGestureAction(_: UITapGestureRecognizer) {
        if srtControl.view.isHidden {
            isMaskShow.toggle()
        } else {
            srtControl.view.isHidden = true
        }
    }

    open func panGestureBegan(location _: CGPoint, direction: KSPanDirection) {
        if direction == .horizontal {
            // 给tmpPanValue初值
            if totalTime > 0 {
                tmpPanValue = toolBar.timeSlider.value
            }
        }
    }

    open func panGestureChanged(velocity point: CGPoint, direction: KSPanDirection) {
        if direction == .horizontal {
            if !KSPlayerManager.enablePlaytimeGestures {
                return
            }
            isSliderSliding = true
            if totalTime > 0 {
                // 每次滑动需要叠加时间，通过一定的比例，使滑动一直处于统一水平
                tmpPanValue += panValue(velocity: point, direction: direction, currentTime: Float(toolBar.currentTime), totalTime: Float(totalTime))
                tmpPanValue = max(min(tmpPanValue, Float(totalTime)), 0)
                showSeekToView(second: Double(tmpPanValue), isAdd: point.x > 0)
            }
        }
    }

    open func panValue(velocity point: CGPoint, direction: KSPanDirection, currentTime _: Float, totalTime: Float) -> Float {
        if direction == .horizontal {
            return max(min(Float(point.x) / 0x40000, 0.01), -0.01) * totalTime
        } else {
            return -Float(point.y) / 0x2800
        }
    }

    open func panGestureEnded() {
        // 移动结束也需要判断垂直或者平移
        // 比如水平移动结束时，要快进到指定位置，如果这里没有判断，当我们调节音量完之后，会出现屏幕跳动的bug
        if scrollDirection == .horizontal, KSPlayerManager.enablePlaytimeGestures {
            hideSeekToView()
            isSliderSliding = false
            slider(value: Double(tmpPanValue), event: .touchUpInside)
            tmpPanValue = 0.0
        }
    }

    #if canImport(UIKit)
    override open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let presse = presses.first else {
            return
        }
        switch presse.type {
        case .playPause:
            if playerLayer.state.isPlaying {
                pause()
            } else {
                play()
            }
        default: super.pressesBegan(presses, with: event)
        }
    }
    #endif
}

// MARK: - seekToView

public extension VideoPlayerView {
    /**
     Call when User use the slide to seek function

     - parameter second:     target time
     - parameter isAdd:         isAdd
     */
    func showSeekToView(second: TimeInterval, isAdd: Bool) {
        isMaskShow = true
        seekToView.isHidden = false
        toolBar.currentTime = second
        seekToView.set(text: second.toString(for: toolBar.timeType), isAdd: isAdd)
    }

    func hideSeekToView() {
        seekToView.isHidden = true
    }
}

// MARK: - private functions

extension VideoPlayerView {
    @objc private func panGestureAction(_ pan: UIPanGestureRecognizer) {
        // 播放结束时，忽略手势,锁屏状态忽略手势
        guard !replayButton.isSelected, !isLock else { return }
        // 根据上次和本次移动的位置，算出一个速率的point
        let velocityPoint = pan.velocity(in: self)
        switch pan.state {
        case .began:
            // 使用绝对值来判断移动的方向
            if abs(velocityPoint.x) > abs(velocityPoint.y) {
                scrollDirection = .horizontal
            } else {
                scrollDirection = .vertical
            }
            panGestureBegan(location: pan.location(in: self), direction: scrollDirection)
        case .changed:
            panGestureChanged(velocity: velocityPoint, direction: scrollDirection)
        case .ended:
            panGestureEnded()
        default:
            break
        }
    }

    private func setupSrtControl() {
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 16)
        subtitleLabel.backingLayer?.shadowColor = UIColor.black.cgColor
        subtitleLabel.backingLayer?.shadowOffset = CGSize(width: 1.0, height: 1.0)
        subtitleLabel.backingLayer?.shadowOpacity = 0.9
        subtitleLabel.backingLayer?.shadowRadius = 1.0
        subtitleLabel.backingLayer?.shouldRasterize = true
//        subtitleBackView.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        subtitleBackView.cornerRadius = 2
        subtitleBackView.addSubview(subtitleLabel)
        subtitleBackView.isHidden = true
        addSubview(subtitleBackView)
        addSubview(srtControl.view)
        srtControl.view.isHidden = true
        subtitleBackView.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        srtControl.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subtitleBackView.bottomAnchor.constraint(equalTo: safeBottomAnchor, constant: -5),
            subtitleBackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleBackView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -10),
            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleBackView.leadingAnchor, constant: 10),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleBackView.trailingAnchor, constant: -10),
            subtitleLabel.topAnchor.constraint(equalTo: subtitleBackView.topAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleBackView.bottomAnchor, constant: -2),
            srtControl.view.topAnchor.constraint(equalTo: topAnchor),
            srtControl.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            srtControl.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            srtControl.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        srtControl.selectWithFilePath = { [weak self] result in
            guard let self = self else { return }
            if let subtitle = try? result.get() {
                self.subtitleBackView.isHidden = false
                self.resource?.subtitle = subtitle
            } else {
                self.subtitleBackView.isHidden = true
                self.resource?.subtitle = nil
            }
        }
    }

    /**
     auto fade out controll view with animtion
     */
    private func autoFadeOutViewWithAnimation() {
        delayItem?.cancel()
        // 播放的时候才自动隐藏
        guard toolBar.playButton.isSelected else { return }
        delayItem = DispatchWorkItem { [weak self] in
            self?.isMaskShow = false
        }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + KSPlayerManager.animateDelayTimeInterval,
                                      execute: delayItem!)
    }

    private func showLoader() {
        loadingIndector.isHidden = false
        loadingIndector.startAnimating()
    }

    private func hideLoader() {
        loadingIndector.isHidden = true
        loadingIndector.stopAnimating()
    }

    private func configureCenterControlButton(_ button: UIButton, type: PlayerButtonType, systemImageName: String, fallbackTitle: String) {
        button.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        button.cornerRadius = skipControlButtonSize / 2
        button.tintColor = .white
        button.tag = type.rawValue
        button.titleFont = .systemFont(ofSize: 16, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.addTarget(self, action: #selector(onButtonPressed(_:)), for: .primaryActionTriggered)
        #if canImport(UIKit)
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        if let image = UIImage(systemName: systemImageName, withConfiguration: symbolConfiguration) {
            button.setImage(image, for: .normal)
        } else {
            button.setTitle(fallbackTitle, for: .normal)
        }
        button.accessibilityLabel = type == .skipBackward ? "Skip back 15 seconds" : "Skip forward 30 seconds"
        #else
        button.setTitle(fallbackTitle, for: .normal)
        #endif
    }

    private func seekRelative(by interval: TimeInterval) {
        guard let player = playerLayer.player, player.seekable else {
            updateSeekAvailability(for: playerLayer.player)
            return
        }
        let currentTime = player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0
        let duration = max(totalTime, player.duration)
        let unclampedTarget = currentTime + interval
        let targetTime: TimeInterval
        if duration.isFinite, duration > 0 {
            targetTime = min(max(unclampedTarget, 0), duration)
        } else {
            targetTime = max(unclampedTarget, 0)
        }
        toolBar.currentTime = targetTime
        seek(time: targetTime)
    }

    private func updateSeekAvailability(for player: MediaPlayerProtocol?) {
        toolBar.timeSlider.isPlayable = player?.seekable == true
        updateCenterSeekControls()
    }

    private func updateCenterPlaybackButton() {
        let state = playerLayer.state
        let alpha: CGFloat = isMaskShow && !isLock ? 1.0 : 0.0
        replayButton.alpha = alpha
        replayButton.isHidden = state == .notSetURL
        if state == .playedToTheEnd {
            replayButton.tag = PlayerButtonType.replay.rawValue
            replayButton.setImage(KSPlayerManager.image(named: "KSPlayer_play"), for: .normal)
            replayButton.isSelected = true
        } else if state.isPlaying {
            replayButton.tag = PlayerButtonType.pause.rawValue
            replayButton.setImage(centerPauseImage(), for: .normal)
            replayButton.isSelected = false
        } else {
            replayButton.tag = PlayerButtonType.play.rawValue
            replayButton.setImage(KSPlayerManager.image(named: "KSPlayer_play"), for: .normal)
            replayButton.isSelected = false
        }
    }

    private func centerPauseImage() -> UIImage? {
        #if canImport(UIKit)
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        return UIImage(systemName: "pause.fill", withConfiguration: symbolConfiguration) ?? KSPlayerManager.image(named: "toolbar_ic_pause")
        #else
        return KSPlayerManager.image(named: "toolbar_ic_pause")
        #endif
    }

    private func updateCenterSeekControls() {
        let isVisible = playerLayer.player?.seekable == true &&
            !replayButton.isHidden &&
            playerLayer.state != .notSetURL &&
            playerLayer.state != .error
        skipBackwardButton.isHidden = !isVisible
        skipForwardButton.isHidden = !isVisible
        let alpha: CGFloat = isVisible && isMaskShow && !isLock ? 1.0 : 0.0
        skipBackwardButton.alpha = alpha
        skipForwardButton.alpha = alpha
    }

    private func updateMuteButton() {
        let isMuted = playerLayer.player?.isMuted ?? false
        toolBar.muteButton.isSelected = isMuted
        #if canImport(UIKit)
        toolBar.muteButton.accessibilityLabel = isMuted ? NSLocalizedString("unmute", comment: "") : NSLocalizedString("mute", comment: "")
        #endif
    }

    private func timelineThumbImage(diameter: CGFloat) -> UIImage? {
        #if canImport(UIKit)
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
        #else
        return nil
        #endif
    }

    open func showSubtile(from subtitle: KSSubtitleProtocol, at time: TimeInterval) {
        let time = time + (resource?.definitions[currentDefinition].options.subtitleDelay ?? 0.0)
        if let part = subtitle.search(for: time) {
            subtitleEndTime = part.end
            if let image = part.image {
                subtitleBackView.image = image
            } else {
                subtitleLabel.attributedText = part.text
            }
        } else {
            if time > subtitleEndTime {
                subtitleBackView.image = nil
                subtitleLabel.attributedText = nil
            }
        }
    }

    private func addConstraint() {
        toolBar.playButton.tintColor = .white
        toolBar.playbackRateButton.tintColor = .white
        toolBar.definitionButton.tintColor = .white
        toolBar.muteButton.tintColor = .white
        toolBar.timeSlider.setThumbImage(timelineThumbImage(diameter: timelineThumbDiameter) ?? KSPlayerManager.image(named: "KSPlayer_slider_thumb"), for: .normal)
        toolBar.timeSlider.setThumbImage(timelineThumbImage(diameter: highlightedTimelineThumbDiameter) ?? KSPlayerManager.image(named: "KSPlayer_slider_thumb_pressed"), for: .highlighted)
        bottomMaskView.addSubview(toolBar.timeSlider)
        toolBar.spacing = 10
        toolBar.addArrangedSubview(toolBar.playButton)
        toolBar.addArrangedSubview(toolBar.timeLabel)
        toolBar.addArrangedSubview(toolBar.playbackRateButton)
        toolBar.addArrangedSubview(toolBar.definitionButton)
        toolBar.addArrangedSubview(toolBar.audioSwitchButton)
        toolBar.addArrangedSubview(toolBar.videoSwitchButton)
        toolBar.addArrangedSubview(toolBar.srtButton)
        toolBar.addArrangedSubview(toolBar.pipButton)
        toolBar.addArrangedSubview(toolBar.muteButton)
        toolBar.audioSwitchButton.isHidden = true
        toolBar.videoSwitchButton.isHidden = true
        if #available(tvOS 14.0, *) {
            toolBar.pipButton.isHidden = !AVPictureInPictureController.isPictureInPictureSupported()
        } else {
            toolBar.pipButton.isHidden = true
        }
        toolBar.setCustomSpacing(20, after: toolBar.timeLabel)
        toolBar.setCustomSpacing(20, after: toolBar.playbackRateButton)
        toolBar.setCustomSpacing(20, after: toolBar.definitionButton)
        toolBar.setCustomSpacing(20, after: toolBar.srtButton)
        contentOverlayView.translatesAutoresizingMaskIntoConstraints = false
        controllerView.translatesAutoresizingMaskIntoConstraints = false
        toolBar.timeSlider.translatesAutoresizingMaskIntoConstraints = false
        topMaskView.translatesAutoresizingMaskIntoConstraints = false
        bottomMaskView.translatesAutoresizingMaskIntoConstraints = false
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingIndector.translatesAutoresizingMaskIntoConstraints = false
        seekToView.translatesAutoresizingMaskIntoConstraints = false
        replayButton.translatesAutoresizingMaskIntoConstraints = false
        skipBackwardButton.translatesAutoresizingMaskIntoConstraints = false
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false
        playerLayer.translatesAutoresizingMaskIntoConstraints = false
        lockButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerLayer.topAnchor.constraint(equalTo: topAnchor),
            playerLayer.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerLayer.bottomAnchor.constraint(equalTo: bottomAnchor),
            playerLayer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentOverlayView.topAnchor.constraint(equalTo: topAnchor),
            contentOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            controllerView.topAnchor.constraint(equalTo: topAnchor),
            controllerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            controllerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            controllerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topMaskView.topAnchor.constraint(equalTo: topAnchor),
            topMaskView.leadingAnchor.constraint(equalTo: leadingAnchor),
            topMaskView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topMaskView.heightAnchor.constraint(equalToConstant: 105),
            navigationBar.topAnchor.constraint(equalTo: topMaskView.topAnchor),
            navigationBar.leadingAnchor.constraint(equalTo: topMaskView.safeLeadingAnchor, constant: 15),
            navigationBar.trailingAnchor.constraint(equalTo: topMaskView.safeTrailingAnchor, constant: -15),
            navigationBar.heightAnchor.constraint(equalToConstant: 44),
            bottomMaskView.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomMaskView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomMaskView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomMaskView.heightAnchor.constraint(equalToConstant: 105),
            toolBar.bottomAnchor.constraint(equalTo: bottomMaskView.safeBottomAnchor),
            toolBar.leadingAnchor.constraint(equalTo: bottomMaskView.safeLeadingAnchor, constant: 10),
            toolBar.trailingAnchor.constraint(equalTo: bottomMaskView.safeTrailingAnchor, constant: -15),
            toolBar.timeSlider.bottomAnchor.constraint(equalTo: toolBar.topAnchor),
            toolBar.timeSlider.leadingAnchor.constraint(equalTo: bottomMaskView.safeLeadingAnchor, constant: 15),
            toolBar.timeSlider.trailingAnchor.constraint(equalTo: bottomMaskView.safeTrailingAnchor, constant: -15),
            toolBar.timeSlider.heightAnchor.constraint(equalToConstant: 30),
            loadingIndector.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingIndector.centerXAnchor.constraint(equalTo: centerXAnchor),
            seekToView.centerYAnchor.constraint(equalTo: centerYAnchor),
            seekToView.centerXAnchor.constraint(equalTo: centerXAnchor),
            seekToView.widthAnchor.constraint(equalToConstant: 100),
            seekToView.heightAnchor.constraint(equalToConstant: 40),
            replayButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            replayButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            replayButton.widthAnchor.constraint(equalToConstant: centerControlButtonSize),
            replayButton.heightAnchor.constraint(equalToConstant: centerControlButtonSize),
            skipBackwardButton.centerYAnchor.constraint(equalTo: replayButton.centerYAnchor),
            skipBackwardButton.trailingAnchor.constraint(equalTo: replayButton.leadingAnchor, constant: -centerControlSpacing),
            skipBackwardButton.widthAnchor.constraint(equalToConstant: skipControlButtonSize),
            skipBackwardButton.heightAnchor.constraint(equalToConstant: skipControlButtonSize),
            skipForwardButton.centerYAnchor.constraint(equalTo: replayButton.centerYAnchor),
            skipForwardButton.leadingAnchor.constraint(equalTo: replayButton.trailingAnchor, constant: centerControlSpacing),
            skipForwardButton.widthAnchor.constraint(equalToConstant: skipControlButtonSize),
            skipForwardButton.heightAnchor.constraint(equalToConstant: skipControlButtonSize),
            lockButton.leadingAnchor.constraint(equalTo: safeLeadingAnchor, constant: 22),
            lockButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func preferredStyle() -> UIAlertController.Style {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .phone ? .actionSheet : .alert
        #else
        return .alert
        #endif
    }
}

public enum KSPlayerTopBarShowCase {
    /// 始终显示
    case always
    /// 只在横屏界面显示
    case horizantalOnly
    /// 不显示
    case none
}

public extension KSPlayerManager {
    /// 顶部返回、标题、AirPlay按钮 显示选项，默认.Always，可选.HorizantalOnly、.None
    static var topBarShowInCase = KSPlayerTopBarShowCase.always
    /// 自动隐藏操作栏的时间间隔 默认5秒
    static var animateDelayTimeInterval = TimeInterval(5)
    /// 开启亮度手势 默认true
    static var enableBrightnessGestures = true
    /// 开启音量手势 默认true
    static var enableVolumeGestures = true
    /// 开启进度滑动手势 默认true
    static var enablePlaytimeGestures = true
    /// 播放内核选择策略 先使用firstPlayer，失败了自动切换到secondPlayer，播放内核有KSAVPlayer、KSMEPlayer两个选项
    /// 是否能后台播放视频
    static var canBackgroundPlay = false
}
