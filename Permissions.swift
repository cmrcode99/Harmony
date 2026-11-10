import Cocoa
import ApplicationServices

/// A grant during a session needs one fresh preparation pass. A grant while
/// focus is off is handled by the normal preparation at the next session start.
struct WindowControlPermissionState {
    private var previousGrant: Bool?
    private var preparationPending = false

    mutating func update(granted: Bool, focusActive: Bool, canPrepare: Bool) -> Bool {
        if previousGrant == false && granted && focusActive { preparationPending = true }
        previousGrant = granted
        if !granted || !focusActive { preparationPending = false }
        guard preparationPending && canPrepare else { return false }
        preparationPending = false
        return true
    }
}

extension App {
    static let windowControlSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    func updateWindowControlMenuItems(granted: Bool) {
        for item in [windowControlItem, applicationWindowControlItem].compactMap({ $0 }) {
            item.title = granted ? "Window control enabled" : "Enable window control…"
            item.isEnabled = !granted
            item.toolTip = granted
                ? "Harmony can minimize allowed app windows when a focus session starts."
                : "Allow Harmony in System Settings → Privacy & Security → Accessibility (Device Control and Data Access on some macOS versions). Harmony will retry window preparation automatically."
        }
    }

    func refreshWindowControlPermission() {
        let granted = checkWindowControlPermission()
        updateWindowControlMenuItems(granted: granted)
        if windowControlPermissionState.update(granted: granted, focusActive: focusEnabled || settingsSuspendedFocus,
            canPrepare: uiReady && !settingsOpen && !interactionsSuspended && !phoneBridge.isBusy && !unlockPromptOpen) {
            launchApprovedApps(launchMissing: false)
        }
    }

    @objc func openWindowControlSettings() {
        // Opening the pane does not request or assume trust. macOS and the user
        // control the switch; the regular timer observes a later grant.
        NSWorkspace.shared.open(Self.windowControlSettingsURL)
    }
}
