import Cocoa
import WebKit
import CryptoKit
import CoreServices

/// Coordinates launch, focus enforcement, timed sessions, and recovery.
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var uiReady = false
    var pendingShow = false
    var initialCommand: HarmonyCommand?
    var panel: FloatingPanel!
    var web: WKWebView!
    var status: NSStatusItem!
    var statusMenu: NSMenu!
    let statusMenuState = HarmonyStatusMenuState()
    var hostedStatusScene: Any?
    var visibleItem: NSMenuItem!
    var moveItem: NSMenuItem!
    var dragOverlay: WindowDragView!
    var movingWindow = false
    var muteItem: NSMenuItem!
    var muted = true
    var playbackPaused = false
    var playbackRevision = 0
    var volume = HarmonyInterface.volume(UserDefaults.standard.object(forKey: "volume") as? Double ?? 70)
    var volumeSlider: NSSlider!
    var volumeButton: NSButton!
    var playbackSlider: NSSlider!
    var skipButton: NSButton!
    weak var playerContainer: HoverView?
    var playerReady = false
    var playerGeneration = 0
    var playerJavaScriptInFlight = false
    var playerStateDirty = true
    var pendingSeek: (position: Double, track: Int)?
    var pendingSkips = 0
    var playlistIndex = 0
    var timer: Timer?
    var lockItem: NSMenuItem!
    var quitItem: NSMenuItem!
    var applicationQuitItem: NSMenuItem?
    var focusEnabled = true
    private var suspensions = FocusSuspensions()
    var interactionsSuspended: Bool { suspensions.isSuspended }
    var savedVideoClickThrough: Bool?
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
        createOverlay()
        installStatusMenu()
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
