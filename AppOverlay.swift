import Cocoa
import WebKit

/// Builds and positions the floating video window and its native controls.
extension App {
    func createOverlay() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakScriptHandler(self), name: "togglePlayback")
        web = InteractiveVideoView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.underPageBackgroundColor = .black
        web.wantsLayer = true
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Harmony"
        panel.level = .floating
        panel.collectionBehavior = HarmonyInterface.overlayBehavior
        panel.animationBehavior = .utilityWindow
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .black
        panel.minSize = NSSize(width: 160, height: 90)
        panel.autorecalculatesKeyViewLoop = true
        let container = HoverView()
        playerContainer = container
        container.onControlsVisibilityChanged = { [weak self] visible in
            if visible { self?.pollPlaybackPosition() }
        }
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        let controls = NSVisualEffectView()
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)
        container.controls = controls
        controls.isHidden = true
        volumeSlider = NSSlider(frame: NSRect(x: 0, y: 0, width: 18, height: 80))
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 100
        volumeSlider.doubleValue = muted ? 0 : volume
        volumeSlider.target = self
        volumeSlider.action = #selector(changeVolume)
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(volumeSlider)
        volumeButton = NSButton(image: NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Toggle sound")!, target: self, action: #selector(sound))
        volumeButton.isBordered = false
        volumeButton.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(volumeButton)
        let playback = NSVisualEffectView()
        playback.material = .hudWindow
        playback.blendingMode = .withinWindow
        playback.state = .active
        playback.wantsLayer = true
        playback.layer?.cornerRadius = 9
        playback.translatesAutoresizingMaskIntoConstraints = false
        playback.isHidden = true
        container.addSubview(playback)
        container.playbackControls = playback
        playbackSlider = NSSlider(value: 0, minValue: 0, maxValue: 3600, target: self, action: #selector(seek(_:)))
        playbackSlider.controlSize = .mini
        playbackSlider.isContinuous = true
        playbackSlider.isEnabled = false
        playbackSlider.setAccessibilityLabel("Playback position in seconds")
        playbackSlider.translatesAutoresizingMaskIntoConstraints = false
        playback.addSubview(playbackSlider)
        skipButton = NSButton(image: NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: "Skip to next video")!, target: self, action: #selector(skipVideo))
        skipButton.isBordered = false
        skipButton.toolTip = "Skip to next video"
        skipButton.setAccessibilityLabel("Skip to next video")
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.isEnabled = false
        playback.addSubview(skipButton)
        NSLayoutConstraint.activate([
            playback.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            playback.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -5),
            playback.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            playback.heightAnchor.constraint(equalToConstant: 26),
            playbackSlider.leadingAnchor.constraint(equalTo: playback.leadingAnchor, constant: 5),
            playbackSlider.trailingAnchor.constraint(equalTo: skipButton.leadingAnchor, constant: -4),
            playbackSlider.centerYAnchor.constraint(equalTo: playback.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: playback.trailingAnchor, constant: -3),
            skipButton.centerYAnchor.constraint(equalTo: playback.centerYAnchor),
            skipButton.widthAnchor.constraint(equalToConstant: 24), skipButton.heightAnchor.constraint(equalToConstant: 24),
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor), web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor), web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            controls.centerYAnchor.constraint(equalTo: container.centerYAnchor), controls.widthAnchor.constraint(equalToConstant: 28),
            controls.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.70),
            volumeButton.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -3),
            volumeButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor), volumeButton.widthAnchor.constraint(equalToConstant: 22), volumeButton.heightAnchor.constraint(equalToConstant: 19),
            volumeSlider.topAnchor.constraint(equalTo: controls.topAnchor, constant: 7), volumeSlider.bottomAnchor.constraint(equalTo: volumeButton.topAnchor, constant: -3),
            volumeSlider.centerXAnchor.constraint(equalTo: controls.centerXAnchor), volumeSlider.widthAnchor.constraint(equalToConstant: 18)
        ])
        dragOverlay = WindowDragView()
        dragOverlay.translatesAutoresizingMaskIntoConstraints = false
        dragOverlay.isHidden = true
        container.addSubview(dragOverlay)
        NSLayoutConstraint.activate([
            dragOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            dragOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        redrawObservers = watchWindowRedraw(panel)
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main) { [weak self] _ in
            self?.web.needsDisplay = true
            self?.web.layer?.setNeedsDisplay()
        }
        let savedWidth = UserDefaults.standard.double(forKey: "videoWidth")
        resize(savedWidth >= 160 && savedWidth <= 1200 ? savedWidth : 320)
        placeInitialWindow()
    }

    func setPhoneInteraction(_ active: Bool) {
        guard uiReady else { return }
        if active {
            if savedVideoClickThrough == nil { savedVideoClickThrough = panel.ignoresMouseEvents }
            panel.ignoresMouseEvents = true
            panel.resignKey()
            moveItem.isEnabled = false
        } else {
            if let previous = savedVideoClickThrough { panel.ignoresMouseEvents = previous }
            savedVideoClickThrough = nil
            moveItem.isEnabled = true
        }
        syncStatusMenu()
    }
    @objc func toggleWindowMovement() {
        guard !phoneBridge.isBusy else { return }
        movingWindow.toggle()
        panel.isMovable = movingWindow
        panel.isMovableByWindowBackground = movingWindow
        dragOverlay.isHidden = !movingWindow
        if movingWindow { panel.styleMask.insert(.resizable) }
        else {
            panel.styleMask.remove(.resizable)
            UserDefaults.standard.set(panel.frame.width, forKey: "videoWidth")
        }
        moveItem.title = movingWindow ? "Fix position" : "Move window"
        syncStatusMenu()
    }
    func resize(_ width: CGFloat) {
        let top = panel.frame.maxY
        let frame = NSRect(x: panel.frame.minX, y: top-width * 9 / 16, width: width, height: width * 9 / 16)
        panel.setFrame(HarmonyInterface.videoFrame(frame, visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                                 fallback: NSScreen.main?.visibleFrame), display: true)
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
    }
    @objc func small() { resize(240); UserDefaults.standard.set(panel.frame.width, forKey: "videoWidth") }
    @objc func medium() { resize(320); UserDefaults.standard.set(panel.frame.width, forKey: "videoWidth") }
    @objc func large() { resize(480); UserDefaults.standard.set(panel.frame.width, forKey: "videoWidth") }
    private func placeInitialWindow() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.minX + 12, y: frame.maxY - panel.frame.height - 47))
    }
    func keepEyeOnScreen() {
        guard uiReady else { return }
        let frame = HarmonyInterface.videoFrame(panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                                fallback: NSScreen.main?.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
}
