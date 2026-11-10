import Cocoa

/// An independent window owns presentation; NSAlert only supplies the native
/// layout. NSAlert's private panel expects its own modal lifecycle, so showing
/// that panel directly as an ordinary window is deliberately avoided here.
@MainActor final class PhonePrompt: NSObject, NSWindowDelegate {
    private final class PromptPanel: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private var alert: NSAlert?
    private var panel: PromptPanel?
    private var input: UnlockField?
    private var completion: ((String?) -> Void)?
    private var requestID: UUID?
    private var observationTokens: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible == true }

    /// Dismiss an outstanding prompt and resolve its awaiting caller once.
    func cancel() { finish(nil) }

    /// Called only for an explicit reopen/activate request. Merely switching to
    /// another approved app must not repeatedly steal keyboard focus back.
    func activate() {
        guard let panel = panel else { return }
        keepOnScreen()
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        if let input = input { panel.makeFirstResponder(input) }
        recordWindowState()
    }

    func present(title: String, detail: String, primary: String, secureInput: Bool, cancel: Bool = true, keyboardOnly: Bool = false) async -> String? {
        guard completion == nil, !Task.isCancelled else { return nil }
        let id = UUID()
        requestID = id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                completion = { continuation.resume(returning: $0) }
                makeWindow(title: title, detail: detail, primary: primary, secureInput: secureInput, cancel: cancel, keyboardOnly: keyboardOnly)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil, request: id) }
        }
    }

    private func makeWindow(title: String, detail: String, primary: String, secureInput: Bool, cancel: Bool, keyboardOnly: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let primaryButton = alert.addButton(withTitle: primary)
        primaryButton.keyEquivalent = "\r"
        if cancel {
            let cancelButton = alert.addButton(withTitle: "Cancel")
            cancelButton.keyEquivalent = "\u{1b}"
        }
        if secureInput {
            let field = UnlockField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
            field.placeholderString = "Type your password exactly"
            alert.accessoryView = field
            input = field
        }
        alert.layout()
        self.alert = alert // Retain the native layout and its accessory view.

        let sourceWindow = alert.window
        guard let nativeContent = sourceWindow.contentView else { finish(nil); return }
        let content = keyboardOnly ? keyboardContent(title: title, detail: detail) : nativeContent
        let size = content.frame.size
        guard size.width > 0, size.height > 0 else { finish(nil); return }
        sourceWindow.contentView = nil
        sourceWindow.orderOut(nil)

        let panel = PromptPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Harmony password"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.canHide = false
        panel.level = .modalPanel
        panel.collectionBehavior = HarmonyInterface.overlayBehavior
        panel.autorecalculatesKeyViewLoop = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onCancel = { [weak self] in self?.finish(nil) }
        if !keyboardOnly { panel.defaultButtonCell = primaryButton.cell as? NSButtonCell }

        let frame = NSRect(origin: .zero, size: size)
        content.frame = frame
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = 14
            glass.contentView = content
            panel.contentView = glass
        } else {
            let glass = NSVisualEffectView(frame: frame)
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 14
            glass.layer?.masksToBounds = true
            glass.addSubview(content)
            panel.contentView = glass
        }
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(buttonPressed(_:))
        }
        self.panel = panel

        // Center on the display where the user is working, not whichever
        // display happens to own the small video window.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        } else { panel.center() }

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification] {
            observationTokens.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                // Observe only. No activation, order-front, or synchronous
                // drawing from these events: those cause focus/redraw loops.
                Task { @MainActor in self?.recordWindowState() }
            })
        }
        observationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.keepOnScreen() }
        })
        activate()
    }

    private func keepOnScreen() {
        guard let panel = panel,
              !NSScreen.screens.contains(where: { screen in
                  let visible = screen.visibleFrame.intersection(panel.frame)
                  return !visible.isNull && visible.width >= 32 && visible.height >= 32
              }), let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
    }

    private func keyboardContent(title: String, detail: String) -> NSView {
        let width: CGFloat = 420
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48)])
        stack.addArrangedSubview(icon)
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(heading)
        let description = NSTextField(wrappingLabelWithString: detail)
        stack.addArrangedSubview(description)
        if let input = input {
            input.translatesAutoresizingMaskIntoConstraints = false
            input.target = self
            input.action = #selector(submitInput(_:))
            stack.addArrangedSubview(input)
            input.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let hint = NSTextField(wrappingLabelWithString: "Enter to submit · Esc to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        for view in [heading, description, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22)
        ])
        root.setFrameSize(NSSize(width: width + 44, height: stack.fittingSize.height + 44))
        return root
    }

    @objc private func submitInput(_ sender: Any?) { finish(input?.stringValue ?? "") }

    @objc private func buttonPressed(_ sender: NSButton) {
        finish(sender.tag == 0 ? (input?.stringValue ?? "") : nil)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func finish(_ value: String?, request id: UUID? = nil) {
        if let id = id, id != requestID { return }
        guard let completion = completion else { return }
        self.completion = nil // Exactly once, including a concurrent cancel.
        requestID = nil
        for token in observationTokens { NotificationCenter.default.removeObserver(token) }
        observationTokens.removeAll()
        if let panel = panel {
            panel.delegate = nil
            panel.onCancel = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        input = nil
        alert = nil
        UserDefaults.standard.set(["visible": false], forKey: "phoneWindowState")
        completion(value)
    }

    private func recordWindowState() {
        guard let panel = panel else { return }
        UserDefaults.standard.set([
            "visible": panel.isVisible,
            "key": panel.isKeyWindow,
            "minimized": panel.isMiniaturized,
            "occluded": !panel.occlusionState.contains(.visible),
            "foreground": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        ], forKey: "phoneWindowState")
    }
}
