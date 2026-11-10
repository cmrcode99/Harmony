import Cocoa
import SwiftUI

/// Native application and menu-bar controls share the same command targets.
extension App {
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "Harmony focus controls")
        menu.delegate = self
        menu.autoenablesItems = false
        visibleItem = add(menu, "Hide Harmony", #selector(toggle))
        muteItem = add(menu, "Unmute", #selector(sound))
        muteItem.identifier = NSUserInterfaceItemIdentifier("mute")
        moveItem = add(menu, "Move window", #selector(toggleWindowMovement))
        settingsItem = add(menu, "Allowed apps", #selector(openAllowedApps))
        videoSettingsItem = add(menu, "Allowed videos", #selector(openAllowedVideos))
        windowControlItem = add(menu, "Enable window control", #selector(openWindowControlSettings))
        updateWindowControlMenuItems(granted: checkWindowControlPermission())
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
        return menu
    }

    func installStatusMenu() {
        let menu = makeStatusMenu()
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
        let settings = add(applicationMenu, "Apps and videos", #selector(openSettings), ",")
        settings.isEnabled = uiReady && !isLocked
        applicationSettingsItem = settings
        applicationWindowControlItem = add(applicationMenu, "Enable window control", #selector(openWindowControlSettings))
        updateWindowControlMenuItems(granted: checkWindowControlPermission())
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
    func syncStatusMenu() {
        if let menu = statusMenu { statusMenuState.update(from: menu) }
    }
    func performStatusMenuItem(_ index: Int) {
        guard uiReady else { return }
        tickLock()
        guard statusMenu.items.indices.contains(index) else { return }
        let item = statusMenu.items[index]
        guard item.isEnabled, !item.isHidden, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}
