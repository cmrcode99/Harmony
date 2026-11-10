import Cocoa
import WebKit
import CryptoKit
import ApplicationServices
import CoreServices
import SwiftUI

final class UnlockField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), ["v", "x"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { return true }
        return super.performKeyEquivalent(with: event)
    }
}
final class HoverView: NSView {
    weak var controls: NSView?
    weak var playbackControls: NSView?
    private(set) var controlsVisible = false
    var onControlsVisibilityChanged: ((Bool) -> Void)?
    func showControls(_ visible: Bool) {
        guard visible != controlsVisible else { return }
        controlsVisible = visible
        controls?.isHidden = !visible
        playbackControls?.isHidden = !visible
        onControlsVisibilityChanged?(visible)
    }
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        if let window = window {
            showControls(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if bounds.contains(point) { showControls(true) }
        return super.hitTest(point)
    }
    override func mouseEntered(with event: NSEvent) { showControls(true) }
    override func mouseExited(with event: NSEvent) { showControls(false) }
}
final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
final class InteractiveVideoView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var uiReady = false
    var pendingShow = false
    var initialCommand: HarmonyCommand?
    var panel: FloatingPanel!
    var web: WKWebView!
    var status: NSStatusItem!
    var statusMenu: NSMenu!
    private let statusMenuState = HarmonyStatusMenuState()
    private var hostedStatusScene: Any?
    var visibleItem: NSMenuItem!
    var moveItem: NSMenuItem!
    var dragOverlay: WindowDragView!
    var movingWindow = false
    var muteItem: NSMenuItem!
    var muted = true
    private var playbackPaused = false
    private var playbackRevision = 0
    var volume = HarmonyInterface.volume(UserDefaults.standard.object(forKey: "volume") as? Double ?? 70)
    var volumeSlider: NSSlider!
    var volumeButton: NSButton!
    var playbackSlider: NSSlider!
    var skipButton: NSButton!
    private weak var playerContainer: HoverView?
    private var playerReady = false
    private var playerGeneration = 0
    private var playerJavaScriptInFlight = false
    private var playerStateDirty = true
    private var pendingSeek: (position: Double, track: Int)?
    private var pendingSkips = 0
    private var playlistIndex = 0
    var timer: Timer?
    var lockItem: NSMenuItem!
    var quitItem: NSMenuItem!
    private var applicationQuitItem: NSMenuItem?
    var focusEnabled = true
    private var suspensions = FocusSuspensions()
    private var interactionsSuspended: Bool { suspensions.isSuspended }
    private var savedVideoClickThrough: Bool?
    lazy var phoneBridge: PhoneBridge = {
        let bridge = PhoneBridge(unlockDigest: unlockDigest)
        bridge.isEnabled = { [weak self] in self?.focusEnabled == true && self?.interactionsSuspended == false }
        bridge.onAccess = { [weak self] active in self?.setPhoneInteraction(active) }
        return bridge
    }()
    private let exitPrompt = PhonePrompt()
    var unlockPromptOpen = false
    private var exitTask: Task<Void, Never>?
    private var exitAuthorized = false
    private var exitRequestedFromEye = false
    var lockUptimeEnd: TimeInterval?
    var lockWallEnd = UserDefaults.standard.double(forKey: "lockEnd")
    private var configuration: AppConfiguration?
    private var configuredAllowedIDs = Set<String>()
    var unlockDigest: String { configuration?.unlockDigest ?? "" }
    var isLocked: Bool { lockRemaining > 0 }
    var lockRemaining: TimeInterval {
        FocusDeadline.remaining(wallDeadline: lockWallEnd, uptimeDeadline: lockUptimeEnd,
                                now: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime)
    }
    var allowedApps: Set<String> { configuredAllowedIDs }
    var activationObserver: NSObjectProtocol?
    var screenObserver: NSObjectProtocol?
    var displayObserver: NSObjectProtocol?
    var sessionObservers: [NSObjectProtocol] = []
    var redrawObservers: [NSObjectProtocol] = []
    var launchingGenerations: [String: Int] = [:]
    private let commandReceipts = HarmonyCommandReceipts()
    lazy var windowPreparation: WindowPreparation = {
        let controller = WindowPreparation()
        controller.isEnabled = { [weak self] in self?.focusEnabled == true }
        return controller
    }()
    private var recoveryAvailable = true
    private var supervisorTask: Process?
    var lastAppScan = Date.distantPast
    static let defaultApprovedPaths = [
        "/Applications/Claude.app", "/Applications/ChatGPT.app", "/Applications/Codex.app",
        "/Applications/cmux.app", "/Applications/Visual Studio Code.app", "/Applications/Cursor.app",
        "/Applications/Zed.app", "/Applications/iTerm.app", "/Applications/Warp.app",
        "/System/Applications/Utilities/Terminal.app", "/System/Library/CoreServices/Finder.app",
        "/System/Applications/iPhone Mirroring.app", "/System/Applications/System Settings.app",
        "/System/Applications/Notes.app"
    ]
    var approvedPaths: [String] {
        configuration?.approvedPaths ?? Self.defaultApprovedPaths
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
#if !HARMONY_TESTING
        let existed = FileManager.default.fileExists(atPath: AppSetup.configurationURL.path)
        guard let configuration = AppSetup.loadOrCreate(defaultPaths: Self.defaultApprovedPaths) else { exit(0) }
        self.configuration = configuration
        configuredAllowedIDs = configuration.approvedIDs
        if CommandLine.arguments.contains("--configure-phone") {
            AppSetup.configurePhone(configuration)
            exit(0)
        }
        // First-run setup is never also consent to force-quit running apps.
        if !existed || CommandLine.arguments.contains("--configure-only") { exit(0) }
#endif
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
        let menu = NSMenu(title: "Harmony focus controls")
        menu.delegate = self
        menu.autoenablesItems = false
        visibleItem = add(menu, "Hide Harmony", #selector(toggle))
        muteItem = add(menu, "Unmute", #selector(sound))
        muteItem.identifier = NSUserInterfaceItemIdentifier("mute")
        moveItem = add(menu, "Move window", #selector(toggleWindowMovement))
        menu.addItem(.separator())
        add(menu, "Small", #selector(small))
        add(menu, "Medium", #selector(medium))
        add(menu, "Large", #selector(large))
        add(menu, "Reload video", #selector(reload))
        menu.addItem(.separator())
        add(menu, "Enter phone passcode…", #selector(phoneEntry))
        lockItem = add(menu, "Start 1-hour lock", #selector(startLock))
        menu.addItem(.separator())
        quitItem = add(menu, "Quit Harmony", #selector(exitFromEye))
        statusMenu = menu
        if #available(macOS 26.0, *) {
            statusMenuState.perform = { [weak self] index in self?.performStatusMenuItem(index) }
            statusMenuState.update(from: menu)
            let scenes = NSHostingSceneRepresentation { HarmonyMenuBarExtra(model: statusMenuState) }
            NSApp.addSceneRepresentation(scenes)
            hostedStatusScene = scenes
        } else {
            status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            HarmonyInterface.configureStatusItem(status)
            status.menu = menu
        }
        uiReady = true
        installApplicationMenu()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(externalToggle(_:)),
            name: HarmonyCommandChannel.commandName, object: nil, suspensionBehavior: .deliverImmediately)
        let now = Date().timeIntervalSince1970
        if let restored = FocusDeadline.restored(lockWallEnd, now: now) {
            lockWallEnd = restored
            lockUptimeEnd = ProcessInfo.processInfo.systemUptime + restored - now
            UserDefaults.standard.set(restored, forKey: "lockEnd")
        } else {
            lockWallEnd = 0
            lockUptimeEnd = nil
            UserDefaults.standard.removeObject(forKey: "lockEnd")
        }
        reload()
        if !focusEnabled || (isLocked && UserDefaults.standard.bool(forKey: "windowHidden")) { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        visibleItem.title = panel.isVisible ? "Hide Harmony" : "Unhide Harmony"
        UserDefaults.standard.set(!panel.isVisible, forKey: "windowHidden")
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.enforceFocus(app)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let suspensionEvents: [(Notification.Name, FocusSuspensions.Reason)] = [
            (NSWorkspace.willSleepNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, .inactiveSession)
        ]
        for (name, reason) in suspensionEvents {
            sessionObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.suspendInteractions(reason)
            })
        }
        let resumeEvents: [(Notification.Name, FocusSuspensions.Reason)] = [
            (NSWorkspace.didWakeNotification, .systemSleep),
            (NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession)
        ]
        for (name, reason) in resumeEvents {
            sessionObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.resumeAfterSuspension(reason)
            })
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepEyeOnScreen()
        }
        // Let the window/event loop finish its first turn before preparation.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.focusEnabled, !self.interactionsSuspended,
                  !self.phoneBridge.isBusy, !self.unlockPromptOpen else { return }
            self.launchApprovedApps()
            self.closeUnapprovedApps()
        }
        if pendingShow {
            pendingShow = false
            showEye(prepareApps: false)
        }
        tickLock()
        startRecoveryHelper()
        let playbackTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickLock()
            self?.pollPlaybackPosition()
            if let self = self, Date().timeIntervalSince(self.lastAppScan) >= 2 {
                self.lastAppScan = Date()
                self.closeUnapprovedApps()
            }
        }
        playbackTimer.tolerance = 0.1
        timer = playbackTimer
        RunLoop.main.add(playbackTimer, forMode: .common)
        if let command = initialCommand, command.action == "lock" {
            beginLock(hours: command.hours!, minutes: command.minutes, prepareApps: false)
        }
    }
    @discardableResult func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item); return item
    }
    func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: "Harmony")
        applicationMenu.autoenablesItems = false
        applicationItem.submenu = applicationMenu
        let about = NSMenuItem(title: "About Harmony", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())
        let hide = add(applicationMenu, "Hide Harmony", #selector(hideFromApplicationMenu), "h")
        hide.isEnabled = uiReady
        applicationMenu.addItem(.separator())
        // Ordinary app Quit retains the timed-session restriction. Only the
        // status item's explicit exit action can request password verification.
        applicationQuitItem = add(applicationMenu, "Quit Harmony", #selector(quit), "q")
        if uiReady {
            let focusItem = NSMenuItem(title: "Focus", action: nil, keyEquivalent: "")
            let focusMenu = NSMenu(title: "Focus")
            focusMenu.autoenablesItems = false
            focusMenu.delegate = self
            focusItem.submenu = focusMenu
            mainMenu.addItem(focusItem)
        }
        NSApp.mainMenu = mainMenu
    }
    @objc private func hideFromApplicationMenu() { hideEye() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard uiReady else { return }
        tickLock()
        if menu !== statusMenu {
            menu.removeAllItems()
            // A menu can have only one owner. Copy the controls so the regular
            // app menu and the system status menu never reparent each other.
            for item in statusMenu.items {
                if let copy = item.copy() as? NSMenuItem {
                    // Keep the eye-only early-exit policy in the app menu too.
                    if copy.action == #selector(exitFromEye) {
                        copy.action = #selector(quit)
                        copy.title = "Quit Harmony"
                        copy.isEnabled = !isLocked
                    }
                    menu.addItem(copy)
                }
            }
        }
    }
    private func syncStatusMenu() {
        if let menu = statusMenu { statusMenuState.update(from: menu) }
    }
    func performStatusMenuItem(_ index: Int) {
        guard uiReady else { return }
        tickLock()
        guard statusMenu.items.indices.contains(index) else { return }
        let item = statusMenu.items[index]
        guard item.isEnabled, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "togglePlayback", message.frameInfo.isMainFrame,
              let state = message.body as? [String: Any],
              let paused = state["paused"] as? Bool,
              let revision = state["revision"] as? Int,
              let generation = state["generation"] as? Int,
              generation == playerGeneration, revision > playbackRevision else { return }
        playbackPaused = paused
        playbackRevision = revision
        if let index = state["index"] as? Int, (0..<1024).contains(index) {
            playlistIndex = index
            pendingSeek = nil
            playbackSlider.isEnabled = false
            playbackSlider.doubleValue = 0
        }
        updatePlayer()
    }
    /// State changes are coalesced; idle playback needs no repeated JS writes.
    func updatePlayer() {
        playerStateDirty = true
        flushPlayerState()
    }
    private func flushPlayerState() {
        guard playerReady, (playerStateDirty || pendingSeek != nil || pendingSkips > 0), !playerJavaScriptInFlight else { return }
        playerStateDirty = false
        let seekPosition = pendingSeek
        pendingSeek = nil
        let skips = pendingSkips
        pendingSkips = 0
        playerJavaScriptInFlight = true
        let generation = playerGeneration
        let js = """
        (() => {
          const v=document.querySelector('video');
          if(!v) return null;
          const targetVolume=\(volume / 100);
          const targetMuted=\((muted || !panel.isVisible) ? "true" : "false");
          if(v.volume!==targetVolume) v.volume=targetVolume;
          if(v.defaultMuted!==targetMuted) v.defaultMuted=targetMuted;
          if(v.muted!==targetMuted) v.muted=targetMuted;
          if(window.harmonyApplyPlayback) window.harmonyApplyPlayback(\(playbackPaused ? "true" : "false"), \(playbackRevision), \(panel.isVisible ? "true" : "false"), \(generation), \(playlistIndex));
          \(skips > 0 ? "if(window.harmonySkipVideo) window.harmonySkipVideo(\(skips));" : "")
          \(seekPosition.map { "if(window.harmonySeekPlayback) window.harmonySeekPlayback(\($0.position),\($0.track));" } ?? "")
          return window.harmonyPlaybackSnapshot ? window.harmonyPlaybackSnapshot() : null;
        })();
        """
        web.evaluateJavaScript(js) { [weak self] value, _ in
            self?.finishPlayerJavaScript(value, generation: generation)
        }
    }
    private func pollPlaybackPosition() {
        guard playerReady, panel.isVisible, playerContainer?.controlsVisible == true,
              !playerJavaScriptInFlight else { return }
        playerJavaScriptInFlight = true
        let generation = playerGeneration
        web.evaluateJavaScript("window.harmonyPlaybackSnapshot ? window.harmonyPlaybackSnapshot() : null") { [weak self] value, _ in
            self?.finishPlayerJavaScript(value, generation: generation)
        }
    }
    private func finishPlayerJavaScript(_ value: Any?, generation: Int) {
        guard generation == playerGeneration else { return }
        playerJavaScriptInFlight = false
        if panel.isVisible, playerContainer?.controlsVisible == true, pendingSeek == nil, pendingSkips == 0,
           let times = value as? [Double], times.count == 4,
           times[2] == Double(playlistIndex), times[3] == Double(playbackRevision),
           times[0].isFinite, times[1].isFinite, times[1] > 0 {
            playbackSlider.isEnabled = true
            playbackSlider.maxValue = times[1]
            if NSEvent.pressedMouseButtons == 0 { playbackSlider.doubleValue = times[0] }
            playbackSlider.toolTip = "\(formatTime(times[0])) / \(formatTime(times[1]))"
        }
        flushPlayerState()
    }

    func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    @objc func seek(_ sender: NSSlider) {
        guard playerReady, sender.isEnabled, pendingSkips == 0, sender.doubleValue.isFinite else { return }
        pendingSeek = (sender.doubleValue, playlistIndex)
        flushPlayerState()
    }
    @objc func skipVideo() {
        guard playerReady, !interactionsSuspended else { return }
        pendingSkips += 1
        pendingSeek = nil
        playbackSlider.isEnabled = false
        playbackSlider.doubleValue = 0
        flushPlayerState()
    }

    func launchApprovedApps() {
        guard focusEnabled else { return }
        let generation = windowPreparation.begin()
        let running = NSWorkspace.shared.runningApplications
        for app in running where allowedApps.contains(app.bundleIdentifier ?? "") && app.bundleIdentifier != "local.harmony.focus" && app.bundleIdentifier != "com.cmuxterm.app" {
            windowPreparation.enqueue(app, generation: generation)
        }
        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })
        for path in approvedPaths {
            let url = URL(fileURLWithPath: path)
            guard let id = Bundle(url: url)?.bundleIdentifier, !runningIDs.contains(id) else { continue }
            let alreadyLaunching = launchingGenerations[id] != nil
            launchingGenerations[id] = generation
            if alreadyLaunching { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let requestedGeneration = self.launchingGenerations.removeValue(forKey: id),
                          self.focusEnabled, let app = app else { return }
                    if id != "com.cmuxterm.app" {
                        self.windowPreparation.enqueue(app, generation: requestedGeneration)
                    }
                }
            }
        }
    }
    func closeUnapprovedApps() {
        tickLock()
        guard !interactionsSuspended, focusEnabled else { return }
        for app in NSWorkspace.shared.runningApplications { closeUnapprovedApp(app) }
    }
    func closeUnapprovedApp(_ app: NSRunningApplication) {
        if let path = app.bundleURL?.path,
           path.hasPrefix("/System/Library/") { return }
        guard focusEnabled, !app.isTerminated, app.activationPolicy == .regular,
              !allowedApps.contains(app.bundleIdentifier ?? ""),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        app.forceTerminate()
    }
    func enforceFocus(_ app: NSRunningApplication) {
        tickLock()
        guard !interactionsSuspended, focusEnabled, !app.isTerminated else { return }
        if let id = app.bundleIdentifier, allowedApps.contains(id) {
            if id != "local.harmony.focus" {
                windowPreparation.userActivated(app)
            }
            return
        }
        // Leave system dialogs and background helpers alone; restrict regular apps.
        if let path = app.bundleURL?.path, path.hasPrefix("/System/Library/") { return }
        guard app.activationPolicy == .regular else { return }
        closeUnapprovedApp(app)
        // Let macOS choose the next window naturally. Never reopen an
        // approved app or move its windows just because another app closed.
    }
    @objc func externalToggle(_ notification: Notification) {
        tickLock()
        guard let action = notification.userInfo?["action"] as? String else { return }
        let hours = (notification.userInfo?["hours"] as? NSNumber).map { $0.stringValue }
        if notification.userInfo?["minutes"] != nil && !(notification.userInfo?["minutes"] is NSNumber) { return }
        let minutes = (notification.userInfo?["minutes"] as? NSNumber).map { $0.stringValue }
        guard let command = HarmonyCommand.parse(action: action, hours: hours, minutes: minutes) else { return }
        let requestID = notification.userInfo?["requestID"] as? String
        // Mutating timer commands require a receipt ID, so a transport retry
        // can never apply the same extension twice.
        guard command.action != "extend" || requestID?.isEmpty == false else { return }
        let decide = { () -> HarmonyCommandReply in
            if let rejection = command.rejection(isLocked: self.isLocked,
                promptBusy: self.unlockPromptOpen || self.phoneBridge.isBusy, focusEnabled: self.focusEnabled) {
                return HarmonyCommandReply(rejection: rejection)
            }
            // Persist an extension before reporting success. Other commands
            // (notably Quit) retain their acknowledgement-before-exit behavior.
            if command.action == "extend" { return self.extendLock(hours: command.hours!, minutes: command.minutes) }
            return HarmonyCommandReply()
        }
        if let requestID = requestID {
            let receipt = commandReceipts.receive(requestID, decide: decide)
            HarmonyCommandChannel.acknowledge(requestID, rejection: receipt.rejection, message: receipt.message)
            guard receipt.isNew, receipt.rejection == nil else { return }
        } else if decide().rejection != nil { return }
        if command.action != "extend" { handleCommand(command.action, hours: command.hours, minutes: command.minutes) }
    }
    func handleCommand(_ action: String, hours: Int?, minutes: Int = 0) {
        switch action {
        case "show": showEye()
        case "unhide": showEye(prepareApps: false)
        case "hide": hideEye()
        case "exit": quit()
        case "phone": phoneEntry()
        case "lock": if let hours = hours { beginLock(hours: hours, minutes: minutes) }
        default: break
        }
    }
    @objc func phoneEntry() {
        guard focusEnabled else { NSSound.beep(); return }
        if unlockPromptOpen { exitPrompt.activate(); return }
        if phoneBridge.isBusy { phoneBridge.activatePrompt(); return }
        windowPreparation.cancel()
        // Phone entry always requires the configured password.
        UserDefaults.standard.removeObject(forKey: "phoneTestUntil")
        phoneBridge.run()
    }
    func showEye(prepareApps: Bool = true) {
        guard uiReady else { pendingShow = true; return }
        if phoneBridge.isBusy { phoneBridge.activatePrompt(); return }
        if unlockPromptOpen {
            exitPrompt.activate()
            return
        }
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if prepareApps { focusEnabled = true; muted = true; syncVolumeControls() }
        web.needsDisplay = true
        if prepareApps { closeUnapprovedApps(); launchApprovedApps() }
        keepEyeOnScreen()
        panel.orderFrontRegardless()
        playerContainer?.updateTrackingAreas()
        UserDefaults.standard.set(false, forKey: "windowHidden")
        visibleItem.title = "Hide Harmony"
        updatePlayer()
        syncStatusMenu()
    }
    func hideEye() {
        playerContainer?.showControls(false)
        panel.orderOut(nil)
        UserDefaults.standard.set(true, forKey: "windowHidden")
        visibleItem.title = "Unhide Harmony"
        updatePlayer()
        syncStatusMenu()
    }
    @objc func toggle() { if panel.isVisible { hideEye() } else { showEye(prepareApps: false) } }
    @objc func sound() {
        muted.toggle()
        if !muted && volume <= 0 {
            volume = 70
            UserDefaults.standard.set(volume, forKey: "volume")
        }
        UserDefaults.standard.set(!muted, forKey: "soundEnabled")
        syncVolumeControls()
        updatePlayer()
    }
    func syncVolumeControls() {
        volumeSlider.doubleValue = muted ? 0 : volume
        volumeButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Toggle sound")
        muteItem.state = muted ? .off : .on
        muteItem.title = muted ? "Unmute" : "Mute"
        syncStatusMenu()
    }
    @objc func changeVolume(_ sender: NSSlider) {
        volume = sender.doubleValue
        muted = volume == 0
        UserDefaults.standard.set(volume, forKey: "volume")
        UserDefaults.standard.set(!muted, forKey: "soundEnabled")
        syncVolumeControls()
        updatePlayer()
    }
    private func setPhoneInteraction(_ active: Bool) {
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
    private func suspendInteractions(_ reason: FocusSuspensions.Reason = .sessionEnding) {
        suspensions.suspend(reason)
        phoneBridge.cancel()
        exitTask?.cancel()
        exitPrompt.cancel()
        windowPreparation.cancel()
        playerContainer?.showControls(false)
    }
    private func resumeAfterSuspension(_ reason: FocusSuspensions.Reason) {
        guard suspensions.resume(reason) else { return }
        tickLock()
        keepEyeOnScreen()
        updatePlayer()
        closeUnapprovedApps()
    }
    private func keepEyeOnScreen() {
        guard uiReady else { return }
        let frame = HarmonyInterface.videoFrame(panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                                fallback: NSScreen.main?.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        playerReady = true
        skipButton.isEnabled = true
        updatePlayer()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }
    @objc func reload() {
        guard let url = Bundle.main.url(forResource: "player", withExtension: "html") else { return }
        playerGeneration += 1
        playbackRevision = 0
        playerReady = false
        pendingSeek = nil
        pendingSkips = 0
        playerJavaScriptInFlight = false
        playerStateDirty = true
        playbackSlider.isEnabled = false
        skipButton.isEnabled = false
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    @objc func startLock() { beginLock(hours: 1) }
    func beginLock(hours: Int, minutes: Int = 0, prepareApps: Bool = true) {
        guard let duration = HarmonyDuration(hours: hours, minutes: minutes), !isLocked,
              !phoneBridge.isBusy, !unlockPromptOpen else { return }
        let seconds = duration.seconds
        lockWallEnd = Date().timeIntervalSince1970 + seconds
        lockUptimeEnd = ProcessInfo.processInfo.systemUptime + seconds
        UserDefaults.standard.set(lockWallEnd, forKey: "lockEnd")
        UserDefaults.standard.synchronize()
        showEye(prepareApps: prepareApps)
        tickLock()
        startRecoveryHelper()
    }
    func extendLock(hours: Int, minutes: Int = 0) -> HarmonyCommandReply {
        guard focusEnabled else { return HarmonyCommandReply(rejection: "Only an active timed Harmony session can be extended.") }
        guard !phoneBridge.isBusy, !unlockPromptOpen else {
            return HarmonyCommandReply(rejection: "Finish or cancel the current password or phone-entry prompt before extending the timer.")
        }
        guard let target = HarmonyDuration(hours: hours, minutes: minutes) else {
            return HarmonyCommandReply(rejection: "Use hours 0–5 and minutes 0–59, for a total of 1 minute to 5 hours.")
        }
        guard target.seconds + 0.000001 >= lockRemaining else {
            return HarmonyCommandReply(rejection: "Cannot shorten an active timer. Choose a target above the current remaining time, up to 5 hours.")
        }
        guard let extended = FocusDeadline.extending(wallDeadline: lockWallEnd, uptimeDeadline: lockUptimeEnd,
            hours: hours, minutes: minutes, now: Date().timeIntervalSince1970, uptime: ProcessInfo.processInfo.systemUptime) else {
            return HarmonyCommandReply(rejection: "Only an active timed Harmony session can be extended to 1 minute–5 hours remaining.")
        }
        UserDefaults.standard.set(extended.wallDeadline, forKey: "lockEnd")
        guard UserDefaults.standard.synchronize() else {
            UserDefaults.standard.set(lockWallEnd, forKey: "lockEnd")
            UserDefaults.standard.synchronize()
            return HarmonyCommandReply(rejection: "Could not save the extended deadline. The timer was left unchanged.")
        }
        lockWallEnd = extended.wallDeadline
        lockUptimeEnd = extended.uptimeDeadline
        tickLock()
        startRecoveryHelper()
        let seconds = Int(ceil(extended.remaining))
        let duration = String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        return HarmonyCommandReply(message: "Harmony timer extended to \(duration) remaining.")
    }
    private func startRecoveryHelper() {
        guard isLocked, !CommandLine.arguments.contains("--supervised"), supervisorTask == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/local.harmony.focus.supervisor"]
        supervisorTask = task
        task.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.supervisorTask = nil
                self.recoveryAvailable = process.terminationStatus == 0
                UserDefaults.standard.set(self.recoveryAvailable, forKey: "recoveryAvailable")
                self.tickLock()
            }
        }
        do { try task.run() }
        catch { supervisorTask = nil; recoveryAvailable = false; tickLock() }
    }
    func tickLock() {
        let locked = isLocked
        if applicationQuitItem?.isEnabled == locked { applicationQuitItem?.isEnabled = !locked }
        let quitTitle = locked ? "Quit Harmony Focus…" : "Quit Harmony"
        if quitItem.title != quitTitle { quitItem.title = quitTitle }
        if lockItem.isEnabled != !locked { lockItem.isEnabled = !locked }
        let lockTitle = locked ? "Locked — \(formatTime(ceil(lockRemaining))) remaining" + (recoveryAvailable ? "" : " (recovery unavailable)") : "Start 1-hour lock"
        if lockItem.title != lockTitle { lockItem.title = lockTitle }
        if !locked && lockWallEnd > 0 {
            lockWallEnd = 0
            lockUptimeEnd = nil
            UserDefaults.standard.removeObject(forKey: "lockEnd")
            focusEnabled = false
            windowPreparation.cancel()
            phoneBridge.cancel()
            if unlockPromptOpen { exitPrompt.cancel() }
            hideEye()
        }
        syncStatusMenu()
    }
    func clearLock() {
        lockWallEnd = 0; lockUptimeEnd = nil
        UserDefaults.standard.removeObject(forKey: "lockEnd")
        UserDefaults.standard.synchronize()
        focusEnabled = false
    }
    @objc func exitFromEye() {
        exitRequestedFromEye = true
        NSApp.terminate(nil)
    }
    private func confirmEmergencyExit() async -> Bool {
        guard isLocked else { return true }
        let entered = await exitPrompt.present(title: "Exit locked Harmony session?",
            detail: "Type the recovery password saved during setup. \(formatTime(ceil(lockRemaining))) remains.",
            primary: "Unlock and exit", secureInput: true, keyboardOnly: true)
        guard isLocked else { return true }
        if let entered = entered {
            let hash = SHA256.hash(data: Data(entered.utf8)).map { String(format: "%02x", $0) }.joined()
            if hash == unlockDigest { clearLock(); return true }
            UserDefaults.standard.set("Password did not match; session remains locked", forKey: "exitStatus")
        }
        return !isLocked
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Starting an existing instance never prepares apps or changes playback.
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard uiReady else { return .terminateNow }
        tickLock()
        let quitReason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        if FocusShutdown.isSystemRequest(quitReason) {
            UserDefaults.standard.set(true, forKey: "sessionEnding")
            UserDefaults.standard.synchronize()
            suspendInteractions()
            return .terminateNow
        }
        guard isLocked && !exitAuthorized else { return .terminateNow }
        guard exitRequestedFromEye else { NSSound.beep(); return .terminateCancel }
        exitRequestedFromEye = false
        if unlockPromptOpen { exitPrompt.activate(); return .terminateCancel }
        unlockPromptOpen = true
        phoneBridge.cancel()
        windowPreparation.cancel()
        exitTask = Task { @MainActor in
            guard !Task.isCancelled else { self.unlockPromptOpen = false; self.exitTask = nil; return }
            let allowed = await self.confirmEmergencyExit()
            self.unlockPromptOpen = false
            self.exitTask = nil
            guard !Task.isCancelled else { return }
            if allowed {
                self.exitAuthorized = true
                NSApp.terminate(nil)
            }
        }
        // Return to the normal event loop so the async prompt can execute.
        // terminateLater would spin inside AppKit and starve this main-queue task.
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard uiReady else { return }
        focusEnabled = false
        phoneBridge.cancel()
        exitTask?.cancel()
        timer?.invalidate()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "togglePlayback")
        windowPreparation.cancel()
        removeWindowRedrawObservers(redrawObservers)
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = displayObserver { NotificationCenter.default.removeObserver(observer) }
        for observer in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
    @objc func quit() { NSApp.terminate(nil) }

}
#if HARMONY_TESTING
MainActor.assumeIsolated { AppIntegrationTests.main() }
#else
if CommandLine.arguments.contains("--install-app") {
    do {
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Harmony.app")
        let backup = try AppSetup.installApp(from: Bundle.main.bundleURL, to: target, lockDirectory: AppSetup.folder)
        if let backup = backup { print("Previous app kept at: \(backup.path)") }
        exit(0)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
}
if CommandLine.arguments.contains("--is-running") {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harmony Focus")
    do {
        let probe = try HarmonyInstanceLock(directory: directory)
        exit(probe.acquire() ? 1 : 0)
    } catch { exit(2) }
}
if let index = CommandLine.arguments.firstIndex(of: "--command") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    guard let command = HarmonyCommand.parse(arguments: args) else { exit(2) }
    var rejection: String?
    guard HarmonyCommandChannel.send(command, onRejection: { rejection = $0 }, onMessage: { print($0) }) else {
        fputs((rejection ?? "Harmony did not acknowledge the command. It may still be starting; try again.") + "\n", stderr)
        exit(1)
    }
    exit(0)
}
let initialCommand: HarmonyCommand?
if let index = CommandLine.arguments.firstIndex(of: "--launch-action") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    guard let command = HarmonyCommand.parse(arguments: args), ["show", "lock"].contains(command.action) else {
        fputs("Invalid launch duration. Use hours 0–5 and minutes 0–59, with a total from 1 minute to 5 hours.\n", stderr)
        exit(2)
    }
    initialCommand = command
} else { initialCommand = nil }
let supervised = CommandLine.arguments.contains("--supervised")
if supervised, FocusDeadline.restored(UserDefaults.standard.double(forKey: "lockEnd"), now: Date().timeIntervalSince1970) == nil { exit(0) }
let runtimeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harmony Focus")
let instanceLock: HarmonyInstanceLock
do { instanceLock = try HarmonyInstanceLock(directory: runtimeDirectory) }
catch { fputs("Could not acquire Harmony's instance lock.\n", stderr); exit(1) }
if supervised {
    // A newly launched login helper clears the preceding session's marker.
    UserDefaults.standard.removeObject(forKey: "sessionEnding")
    let shouldStart = FocusRecovery.waitForOwnership(isActive: {
        UserDefaults.standard.synchronize()
        return !UserDefaults.standard.bool(forKey: "sessionEnding") && FocusDeadline.restored(UserDefaults.standard.double(forKey: "lockEnd"), now: Date().timeIntervalSince1970) != nil
    }, acquire: { instanceLock.acquire() })
    guard shouldStart else { exit(0) }
} else if !instanceLock.acquire() {
    fputs("Another instance of Harmony is already running.\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = App()
delegate.initialCommand = initialCommand
app.delegate = delegate
app.run()
#endif
