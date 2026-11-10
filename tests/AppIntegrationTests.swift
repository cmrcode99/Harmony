import Cocoa

private final class MenuActionProbe: NSObject {
    var calls = 0
    @objc func fire() { calls += 1 }
}

/// Exercise the production menu/controller code without launching focus mode,
/// opening windows, requesting permissions, or touching the live app's domain.
struct AppIntegrationTests {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--ui-smoke") {
            runUISmoke()
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let controller = App()
        controller.lockWallEnd = 0
        controller.focusEnabled = false
        controller.settingsOpen = true
        controller.beginLock(hours: 1)
        precondition(controller.lockWallEnd == 0, "Settings allowed a timed session to start")
        controller.settingsOpen = false
        controller.installApplicationMenu()
        let setupMenu = application.mainMenu!.items[0].submenu!
        precondition(setupMenu.items.first(where: { $0.keyEquivalent == "h" })?.isEnabled == false,
                     "Setup exposed Hide before the video panel exists")
        precondition(application.mainMenu?.item(withTitle: "Focus") == nil,
                     "Setup exposed controls before initialization")
        precondition(setupMenu.items.contains(where: { $0.keyEquivalent == "q" }), "Setup has no normal Quit")

        let menuProbe = App()
        menuProbe.checkWindowControlPermission = { false }
        let menu = menuProbe.makeStatusMenu()
        let titles = menu.items.map(\.title)
        let moveIndex = titles.firstIndex(of: "Move window")!
        precondition(titles[moveIndex + 1] == "Allowed apps" && titles[moveIndex + 2] == "Allowed videos")
        precondition(menu.items[moveIndex + 1].action == #selector(App.openAllowedApps))
        precondition(menu.items[moveIndex + 2].action == #selector(App.openAllowedVideos))
        precondition(SettingsSection.apps.finderDirectory.path == "/Applications")
        precondition(SettingsSection.videos.finderDirectory.isFileURL)
        print("PASS settings shortcuts: menu placement, section routing and Finder directories")
        testWindowControlPermissions(menuProbe)

        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.isVisible = false
        defer { NSStatusBar.system.removeStatusItem(item) }
        controller.status = item
        let statusMenu = NSMenu()
        statusMenu.autoenablesItems = false
        controller.lockItem = controller.add(statusMenu, "Start 1-hour lock", #selector(App.startLock))
        controller.quitItem = controller.add(statusMenu, "Quit Harmony", #selector(App.exitFromEye))
        item.menu = statusMenu
        controller.statusMenu = statusMenu
        controller.uiReady = true
        controller.installApplicationMenu()
        let focusMenu = application.mainMenu!.item(withTitle: "Focus")!.submenu!
        let normalQuit = application.mainMenu!.items[0].submenu!.items.first(where: { $0.keyEquivalent == "q" })!

        controller.lockWallEnd = Date().timeIntervalSince1970 + 3600
        controller.menuNeedsUpdate(focusMenu)
        precondition(!normalQuit.isEnabled, "Ordinary Quit bypassed a timed session")
        let copiedQuit = focusMenu.items.last!
        precondition(!copiedQuit.isEnabled && copiedQuit.action == #selector(App.quit),
                     "App menu acquired the eye-only password-exit action")
        precondition(controller.quitItem.isEnabled && controller.quitItem.action == #selector(App.exitFromEye),
                     "Eye-menu password exit was disabled or replaced")
        precondition(item.menu === statusMenu && statusMenu.items.count == 2,
                     "Opening the app menu stole the status menu's items")
        precondition(copiedQuit !== controller.quitItem, "Menus share an owned menu item")

        controller.lockWallEnd = 0
        controller.menuNeedsUpdate(focusMenu)
        precondition(normalQuit.isEnabled && focusMenu.items.last!.isEnabled,
                     "Ordinary Quit did not return after the timed session")
        let probe = MenuActionProbe()
        let action = NSMenuItem(title: "Probe", action: #selector(MenuActionProbe.fire), keyEquivalent: "")
        action.target = probe
        action.isEnabled = false
        statusMenu.addItem(action)
        controller.performStatusMenuItem(2)
        controller.performStatusMenuItem(-1)
        controller.performStatusMenuItem(100)
        precondition(probe.calls == 0, "Modern menu dispatched a disabled or stale action")
        action.isEnabled = true
        controller.performStatusMenuItem(2)
        precondition(probe.calls == 1, "Modern menu failed to dispatch the original command target")

        let snapshot = HarmonyStatusMenuState()
        var publications = 0
        let subscription = snapshot.$entries.dropFirst().sink { _ in publications += 1 }
        snapshot.update(from: statusMenu)
        snapshot.update(from: statusMenu)
        precondition(publications == 1, "Unchanged timer ticks republished the whole status menu")
        action.identifier = NSUserInterfaceItemIdentifier("mute")
        action.state = .on
        snapshot.update(from: statusMenu)
        precondition(snapshot.entries[2].toggle && snapshot.entries[2].checked,
                     "Modern menu lost the native mute checkmark")
        statusMenu.items[0].isHidden = true
        snapshot.update(from: statusMenu)
        precondition(snapshot.entries.map(\.id) == [1, 2], "Hidden controls changed command indices")
        action.isHidden = true
        controller.performStatusMenuItem(2)
        precondition(probe.calls == 1, "Modern menu dispatched a hidden action")
        withExtendedLifetime(subscription) {}
        print("PASS production menus: setup readiness, native app controls, eye-only timed exit, independent menu ownership")
        print("PASS modern status menu: original command dispatch, disabled/stale action rejection, change-only snapshots, toggle state")
        testTimerExtension(controller)
        testSettingsLibrary()
        testPlaybackSnapshots(controller)
    }

    @MainActor private static func testWindowControlPermissions(_ controller: App) {
        controller.focusEnabled = false
        controller.installApplicationMenu()
        controller.refreshWindowControlPermission()
        for item in [controller.windowControlItem!, controller.applicationWindowControlItem!] {
            precondition(item.title == "Enable window control" && item.isEnabled && !item.isHidden)
            precondition(item.action == #selector(App.openWindowControlSettings))
            precondition(item.toolTip?.contains("Accessibility") == true)
        }
        controller.checkWindowControlPermission = { true }
        controller.refreshWindowControlPermission()
        for item in [controller.windowControlItem!, controller.applicationWindowControlItem!] {
            precondition(item.isHidden && !item.isEnabled, "Granted permission left an unnecessary menu row")
        }
        precondition(App.windowControlSettingsURL.scheme == "x-apple.systempreferences")

        var state = WindowControlPermissionState()
        precondition(!state.update(granted: true, focusActive: true, canPrepare: true), "Initial trust duplicated normal startup preparation")
        precondition(!state.update(granted: false, focusActive: true, canPrepare: true))
        precondition(state.update(granted: true, focusActive: true, canPrepare: true), "New grant did not retry active focus preparation")
        for _ in 0..<10 {
            precondition(!state.update(granted: true, focusActive: true, canPrepare: true), "Unchanged permission continuously prepared windows")
        }
        precondition(!state.update(granted: false, focusActive: true, canPrepare: false))
        precondition(!state.update(granted: true, focusActive: true, canPrepare: false), "Permission retry ran during a prompt or suspension")
        precondition(state.update(granted: true, focusActive: true, canPrepare: true), "Deferred grant was lost")
        precondition(!state.update(granted: false, focusActive: false, canPrepare: false))
        precondition(!state.update(granted: true, focusActive: false, canPrepare: false))
        precondition(!state.update(granted: true, focusActive: true, canPrepare: true), "An inactive grant duplicated the next session preparation")
        precondition(!state.update(granted: false, focusActive: true, canPrepare: false))
        precondition(!state.update(granted: true, focusActive: true, canPrepare: false))
        precondition(!state.update(granted: false, focusActive: true, canPrepare: true), "Revocation preserved a stale retry")
        precondition(state.update(granted: true, focusActive: true, canPrepare: true))

        // The controller has no configured allowed IDs. Injecting the worker
        // also prevents these headless checks from touching AX or preferences.
        controller.windowPreparation = WindowPreparation(probe: { _, _ in .init(complete: true, eligibleWindows: 0, message: nil) }, publish: { _ in })
        controller.windowControlPermissionState = WindowControlPermissionState()
        controller.uiReady = true
        controller.focusEnabled = true
        controller.checkWindowControlPermission = { false }
        controller.refreshWindowControlPermission()
        controller.settingsOpen = true
        controller.settingsSuspendedFocus = true
        controller.focusEnabled = false
        controller.checkWindowControlPermission = { true }
        controller.refreshWindowControlPermission()
        precondition(controller.windowPreparation.generation == 0, "Settings pause prepared windows")
        controller.settingsOpen = false
        controller.settingsSuspendedFocus = false
        controller.focusEnabled = true
        controller.launchingGenerations["test.harmony.pending-launch"] = 0
        controller.refreshWindowControlPermission()
        precondition(controller.windowPreparation.generation == 1, "Closing settings lost the newly granted permission")
        precondition(controller.launchingGenerations["test.harmony.pending-launch"] == 1,
                     "A pending app launch retained its stale permission generation")
        controller.refreshWindowControlPermission()
        precondition(controller.windowPreparation.generation == 1, "Controller repeated permission preparation")
        controller.focusEnabled = false
        print("PASS window control: clear menu status, settings action, one retry per grant, prompt deferral, inactive grant and revocation handling")
    }

    @MainActor private static func testPlaybackSnapshots(_ controller: App) {
        // Native controls can be tested without showing a window or loading WebKit.
        controller.playbackSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        controller.playlistIndex = 2
        controller.playbackRevision = 7
        controller.pendingSeek = nil
        controller.pendingSkips = 0
        let current: [Double] = [12, 120, 2, 7]
        controller.applyPlaybackSnapshot(current, isDragging: false)
        precondition(controller.playbackSlider.isEnabled && controller.playbackSlider.maxValue == 120)
        precondition(controller.playbackSlider.doubleValue == 12 && controller.playbackSlider.toolTip != nil)

        for missing in [nil, [12, 120], [Double.nan, 120, 2, 7], [12, Double.infinity, 2, 7]] as [[Double]?] {
            controller.applyPlaybackSnapshot(missing, isDragging: false)
            precondition(!controller.playbackSlider.isEnabled && controller.playbackSlider.doubleValue == 0 &&
                         controller.playbackSlider.maxValue == 0 && controller.playbackSlider.toolTip == nil,
                         "Unavailable or invalid media left a stale native seek control")
            controller.applyPlaybackSnapshot(current, isDragging: false)
        }
        controller.applyPlaybackSnapshot([20, 140, 1, 7] as [Double], isDragging: false)
        controller.applyPlaybackSnapshot([20, 140, 2, 6] as [Double], isDragging: false)
        precondition(controller.playbackSlider.isEnabled && controller.playbackSlider.doubleValue == 12 &&
                     controller.playbackSlider.maxValue == 120, "A stale source/revision changed the current timeline")
        controller.applyPlaybackSnapshot([30, 120, 2, 7] as [Double], isDragging: true)
        precondition(controller.playbackSlider.doubleValue == 12, "Playback polling moved a slider during a drag")
        controller.pendingSeek = (18, 2)
        controller.applyPlaybackSnapshot(nil, isDragging: false)
        precondition(controller.playbackSlider.isEnabled && controller.playbackSlider.doubleValue == 12,
                     "A pending seek was cleared by a transitional snapshot")
        controller.pendingSeek = nil
        controller.pendingSkips = 1
        controller.applyPlaybackSnapshot(nil, isDragging: false)
        precondition(controller.playbackSlider.isEnabled, "A pending skip was cleared by a transitional snapshot")
        controller.pendingSkips = 0
        controller.playerGeneration = 3
        controller.playerJavaScriptInFlight = true
        controller.finishPlayerJavaScript(nil, generation: 2)
        precondition(controller.playerJavaScriptInFlight && controller.playbackSlider.isEnabled,
                     "An old page's callback changed the new page's native controls")
        controller.playerJavaScriptInFlight = false
        print("PASS native playback snapshots: unavailable timeline clearing, valid restoration, stale generation/revision rejection, pending seek/skip preservation")
    }

    @MainActor private static func testSettingsLibrary() {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("harmony-settings-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let library = VideoLibrary(directory: root.appendingPathComponent("Media"))
            let first = root.appendingPathComponent("my #video.mp4")
            let second = root.appendingPathComponent("second.mov")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            let one = try library.importVideo(first)
            let two = try library.importVideo(second)
            let initialLibrary = try library.load()
            precondition(initialLibrary == nil)
            try library.save([one, two])
            let config = AppConfiguration(unlockDigest: String(repeating: "a", count: 64), approvedPaths: [])
            let model = HarmonySettingsModel(configuration: config, library: library)
            model.selectedApp = HarmonySettingsModel.fixedApps[0]
            model.removeApp()
            precondition(model.appPaths.contains(HarmonySettingsModel.fixedApps[0]))
            let application = root.appendingPathComponent("Editor.app/Contents")
            try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.harmony.editor", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try info.write(to: application.appendingPathComponent("Info.plist"))
            model.addApps([application.deletingLastPathComponent(), application.deletingLastPathComponent()])
            precondition(model.appPaths.filter { $0.hasSuffix("Editor.app") }.count == 1)
            model.selectedVideo = two.id
            model.moveVideo(-1)
            precondition(model.videos.map(\.id) == [two.id, one.id])
            model.selectedVideo = one.id
            model.removeVideo()
            model.onSave = { _ in throw CocoaError(.fileWriteNoPermission) }
            model.save()
            let unchanged = try library.load()
            precondition(unchanged == [one, two], "Failed settings save changed the playlist")
            precondition(FileManager.default.fileExists(atPath: library.clips.appendingPathComponent(one.file).path))
            var saved: AppConfiguration?
            model.onSave = { saved = $0 }
            model.save()
            precondition(saved?.unlockDigest == config.unlockDigest, "Settings changed the recovery password")
            precondition(saved?.approvedIDs.contains("test.harmony.editor") == true)
            let restored = try library.load()
            precondition(restored == [two])
            precondition(FileManager.default.fileExists(atPath: first.path), "Removing a video deleted its original")
            precondition(!FileManager.default.fileExists(atPath: library.clips.appendingPathComponent(one.file).path))
            let html = root.appendingPathComponent("player.html")
            try Data("<video></video>".utf8).write(to: html)
            let page = try library.playerURL(bundledPlayer: html)
            precondition(page.deletingLastPathComponent().standardizedFileURL.path == library.directory.standardizedFileURL.path, "Custom player left its allowed library directory")
            let script = try String(contentsOf: library.directory.appendingPathComponent("playlist.js"), encoding: .utf8)
            precondition(script.contains(two.file))
            try library.save(nil)
            let defaultLibrary = try library.load()
            let defaultPlayer = try library.playerURL(bundledPlayer: html)
            precondition(defaultLibrary == nil && defaultPlayer == html)
            let cancellation = ImportCancellation(); cancellation.cancel()
            var cancelled = false
            do { _ = try library.importVideo(first, cancellation: cancellation) } catch { cancelled = true }
            precondition(cancelled)
            let external = root.appendingPathComponent("originals")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let protectedVideo = external.appendingPathComponent(one.file)
            try Data("original".utf8).write(to: protectedVideo)
            let linked = VideoLibrary(directory: root.appendingPathComponent("linked-library"))
            try FileManager.default.createDirectory(at: linked.directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linked.clips, withDestinationURL: external)
            try linked.save(nil)
            precondition(FileManager.default.fileExists(atPath: protectedVideo.path), "Cleanup followed a directory link into original media")
            print("PASS settings: protected apps, playlist ordering/removal, private copies, password preservation and cancellation")
        } catch { fatalError("Settings regression failed: \(error)") }
    }

    @MainActor private static func testTimerExtension(_ controller: App) {
        // Reuse the production helper guard so these tests never kickstart the
        // real user's recovery job. Production startup is excluded in this build.
        precondition(CommandLine.arguments.contains("--supervised"))
        precondition(Bundle.main.bundleIdentifier != "local.harmony.focus")
        let defaults = UserDefaults.standard
        let savedDeadline = defaults.object(forKey: "lockEnd")
        defer {
            if let saved = savedDeadline { defaults.set(saved, forKey: "lockEnd") }
            else { defaults.removeObject(forKey: "lockEnd") }
            defaults.synchronize()
        }
        controller.panel = FloatingPanel(contentRect: NSRect(x: 20, y: 100, width: 320, height: 180),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controller.panel.isReleasedWhenClosed = false
        controller.focusEnabled = true
        controller.lockWallEnd = Date().timeIntervalSince1970 + 7200
        controller.lockUptimeEnd = ProcessInfo.processInfo.systemUptime + 7200
        controller.volume = 42
        controller.muted = false
        let frame = controller.panel.frame
        let generation = controller.windowPreparation.generation
        let oldWall = controller.lockWallEnd
        let oldUptime = controller.lockUptimeEnd!
        let result = controller.extendLock(hours: 4, minutes: 30)
        precondition(result.rejection == nil && result.message?.contains("remaining") == true)
        precondition(result.message?.contains("4:30:00 remaining") == true, "CLI result did not report the requested target")
        precondition(abs(controller.lockWallEnd - oldWall - 9000) < 0.2)
        precondition(abs(controller.lockUptimeEnd! - oldUptime - 9000) < 0.2)
        precondition(defaults.double(forKey: "lockEnd") == controller.lockWallEnd, "Accepted extension was not persisted")
        precondition(controller.focusEnabled && !controller.panel.isVisible && controller.panel.frame == frame,
                     "Extension changed focus or revealed/moved the hidden eye")
        precondition(controller.volume == 42 && !controller.muted && controller.windowPreparation.generation == generation,
                     "Extension reset sound or repeated app preparation")

        func notify(_ hours: Int, minutes: Int = 0, id: String?) {
            var info: [String: Any] = ["action": "extend", "hours": hours]
            if minutes != 0 { info["minutes"] = minutes }
            if let id = id { info["requestID"] = id }
            controller.externalToggle(Notification(name: HarmonyCommandChannel.commandName, userInfo: info))
        }
        let id = UUID().uuidString
        notify(4, minutes: 45, id: id)
        let once = controller.lockWallEnd
        notify(4, minutes: 45, id: id)
        precondition(controller.lockWallEnd == once, "A retried request extended twice")
        notify(5, id: nil)
        notify(5, id: "")
        notify(6, id: UUID().uuidString)
        notify(5, minutes: 1, id: UUID().uuidString)
        notify(4, minutes: 60, id: UUID().uuidString)
        controller.externalToggle(Notification(name: HarmonyCommandChannel.commandName,
            userInfo: ["action": "extend", "hours": 5, "minutes": "bad", "requestID": UUID().uuidString]))
        precondition(controller.lockWallEnd == once, "Unidentified or malformed command changed the deadline")
        controller.unlockPromptOpen = true
        notify(5, id: UUID().uuidString)
        precondition(controller.lockWallEnd == once, "Extension changed an open password prompt's session")
        controller.unlockPromptOpen = false
        let shorter = controller.extendLock(hours: 4)
        precondition(shorter.rejection?.contains("shorten") == true && controller.lockWallEnd == once,
                     "Smaller extension target shortened the timer")
        let maximum = controller.extendLock(hours: 5)
        precondition(maximum.message?.contains("5:00:00 remaining") == true)
        precondition(controller.lockRemaining <= 18_000 && controller.lockRemaining > 17_999,
                     "Extension did not enforce the five-hour remaining cap")
        controller.lockWallEnd = 0
        controller.lockUptimeEnd = nil
        controller.focusEnabled = false
        notify(5, id: id) // A late retry keeps its original receipt without reviving the session.
        notify(5, id: UUID().uuidString)
        precondition(controller.lockWallEnd == 0 && !controller.focusEnabled,
                     "Extension revived an expired session")
        controller.panel.close()
        print("PASS production extension: persisted clocks, unchanged UI/audio/preparation, exactly-once retries, busy/expired rejection, cap")
    }

    /// A real event-loop check complements controller tests: it catches scene
    /// update loops and failed WebKit startup that a typecheck cannot detect.
    @MainActor private static func runUISmoke() {
        let application = NSApplication.shared
        let controller = App()
        controller.focusEnabled = false
        controller.lockWallEnd = 0
        let minuteTimer = CommandLine.arguments.contains("--minute-timer")
        if minuteTimer { controller.initialCommand = HarmonyCommand(action: "lock", hours: 0, minutes: 1) }
        application.delegate = controller
        var samples = 0
        var successes = 0
        var checkingPlaylist = false
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !checkingPlaylist else { return }
                samples += 1
                if samples > 16 { fputs("UI startup did not become ready.\n", stderr); exit(1) }
                guard controller.uiReady else { return }
                controller.web.evaluateJavaScript("(() => { const v=document.querySelector('video'); const s=window.harmonyPlaybackSnapshot?.(); return !!s && s[1]>0 && v.muted && !v.paused; })()") { value, error in
                    if error == nil, value as? Bool == true { successes += 1 }
                    if successes >= 3 {
                        if minuteTimer {
                            guard controller.isLocked, !controller.focusEnabled,
                                  controller.lockRemaining <= 60, controller.lockRemaining > 30 else {
                                fputs("Minute-duration startup did not initialize the expected deadline.\n", stderr)
                                exit(1)
                            }
                            print("PASS live minute startup: one-minute deadline, enforcement disabled, recovery helper suppressed")
                        }
                        print("PASS live UI startup: responsive event loop, system status scene, local video metadata, muted playback")
                        if CommandLine.arguments.contains("--playlist-smoke") {
                            checkingPlaylist = true
                            Task { @MainActor in
                                do { try await checkPlaylist(controller); exit(0) }
                                catch { fputs("Playlist smoke test failed: \(error)\n", stderr); exit(1) }
                            }
                        } else { exit(0) }
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        application.run()
    }
    @MainActor private static func checkPlaylist(_ controller: App) async throws {
        let deadline = controller.lockWallEnd
        let focusEnabled = controller.focusEnabled
        _ = try await controller.web.evaluateJavaScript("(() => { document.querySelector('video').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter'})); return true; })()")
        let container = controller.panel.contentView as! HoverView
        container.showControls(true)
        controller.resize(160)
        container.layoutSubtreeIfNeeded()
        precondition(!controller.skipButton.isHiddenOrHasHiddenAncestor && controller.skipButton.frame.width >= 24,
                     "Skip is inaccessible at the smallest window size")
        for expected in [1, 2, 3, 0] {
            controller.volume = 37
            controller.muted = expected == 1 || expected == 2
            controller.updatePlayer()
            controller.skipButton.performClick(nil)
            var loaded = false
            for _ in 0..<40 {
                let state = try await controller.web.evaluateJavaScript("(() => { const v=document.querySelector('video'); const s=window.harmonyPlaybackSnapshot?.(); return s ? [s[2],s[1],v.paused?1:0,v.muted?1:0,v.volume,v.currentTime,s[0]] : null; })()")
                if let values = state as? [Double], values.count == 7, values[0] == Double(expected), values[1] > 0 {
                    precondition(values[2] == 1 && values[3] == (controller.muted ? 1 : 0) && abs(values[4] - 0.37) < 0.001,
                                 "Skip changed pause, mute or volume")
                    precondition(abs(values[5] - 120) < 0.1 && abs(values[6]) < 0.1,
                                 "A video did not start at its two-minute trim point")
                    loaded = true; break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            precondition(loaded, "Playlist file did not load through the actual native Skip button")
            precondition(controller.lockWallEnd == deadline && controller.focusEnabled == focusEnabled,
                         "Skip changed the focus session or timer")
        }
        print("PASS live playlist: hover Skip at minimum size, all four actual files start at 2:00 with relative timeline, wraparound, pause/mute/volume and unchanged focus/deadline")
    }
}
