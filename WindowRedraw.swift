import Cocoa

// Repair backing-store invalidation after exposure/screen changes without
// changing the alert's native appearance or its secure input behavior.
func watchWindowRedraw(_ window: NSWindow) -> [NSObjectProtocol] {
    let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification,
        NSWindow.didExposeNotification, NSWindow.didChangeScreenNotification,
        NSWindow.didChangeOcclusionStateNotification]
    return names.map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
            guard let window = window, window.isVisible else { return }
            window.contentView?.needsDisplay = true
        }
    }
}
func removeWindowRedrawObservers(_ tokens: [NSObjectProtocol]) {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
}
