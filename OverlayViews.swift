import Cocoa
import WebKit

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
