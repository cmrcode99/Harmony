import Cocoa

/// A phone-only launch never constructs the focus controller or its enforcement observers.
@MainActor final class PhoneEntryApp: NSObject, NSApplicationDelegate {
    private var bridge: PhoneBridge?
    private var sessionObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let configuration: AppConfiguration
        do {
            configuration = try AppSetup.loadConfiguration(from: AppSetup.configurationURL)
        } catch {
            AppSetup.notice("Phone entry unavailable", "Open Harmony Settings to check your configuration, then try again.")
            NSApp.terminate(nil)
            return
        }
        let bridge = PhoneBridge(unlockDigest: configuration.unlockDigest)
        self.bridge = bridge
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveCommand(_:)),
            name: HarmonyCommandChannel.commandName, object: nil, suspensionBehavior: .deliverImmediately)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak bridge] _ in
                MainActor.assumeIsolated { bridge?.cancel() }
            })
        }
        bridge.run { NSApp.terminate(nil) }
    }

    func handleCommand(_ action: String) -> HarmonyCommandReply {
        switch action {
        case "phone": bridge?.activatePrompt()
        case "exit": bridge?.cancel()
        default: return HarmonyCommandReply(rejection: "Phone entry is open. Finish or cancel it before using focus controls.")
        }
        return HarmonyCommandReply()
    }

    @objc private func receiveCommand(_ notification: Notification) {
        guard let action = notification.userInfo?["action"] as? String,
              let requestID = notification.userInfo?["requestID"] as? String else { return }
        let reply = handleCommand(action)
        HarmonyCommandChannel.acknowledge(requestID, rejection: reply.rejection)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bridge?.activatePrompt()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.cancel()
        DistributedNotificationCenter.default().removeObserver(self)
        for token in sessionObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
