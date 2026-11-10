import Cocoa
import SwiftUI

/// A value snapshot of the same NSMenu used by the AppKit controls. The modern
/// system host renders it; command targets and session policy stay in App.
final class HarmonyStatusMenuState: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: Int
        let title: String
        let enabled: Bool
        let separator: Bool
        let toggle: Bool
        let checked: Bool
    }
    @Published private(set) var entries: [Entry] = []
    var perform: (Int) -> Void = { _ in }

    func update(from menu: NSMenu) {
        let next = menu.items.enumerated().filter { !$0.element.isHidden }.map { index, item in
            Entry(id: index, title: item.title, enabled: item.isEnabled,
                  separator: item.isSeparatorItem, toggle: item.identifier?.rawValue == "mute",
                  checked: item.state == .on)
        }
        if next != entries { entries = next }
    }
}

@available(macOS 26.0, *)
struct HarmonyMenuBarExtra: Scene {
    let model: HarmonyStatusMenuState
    var body: some Scene {
        MenuBarExtra("Harmony focus controls", systemImage: "eye.fill") {
            HarmonyStatusMenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct HarmonyStatusMenuContent: View {
    @ObservedObject var model: HarmonyStatusMenuState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.entries) { entry in
                if entry.separator {
                    Divider()
                } else if entry.toggle {
                    Toggle(entry.title, isOn: Binding(get: { entry.checked }, set: { _ in perform(entry.id) }))
                        .toggleStyle(.checkbox)
                        .disabled(!entry.enabled)
                } else {
                    Button { perform(entry.id) } label: {
                        Text(entry.title).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!entry.enabled)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
    private func perform(_ index: Int) {
        dismiss()
        // Let the menu host close before opening an AppKit settings window.
        let action = model.perform
        DispatchQueue.main.async { action(index) }
    }
}

/// Shared AppKit policy for the video and password panels. Joining other apps
/// and being eligible to accompany a full-screen window are separate options.
enum HarmonyInterface {
    static let overlayBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
        .fullScreenDisallowsTiling, .transient, .ignoresCycle
    ]

    static func configureStatusItem(_ item: NSStatusItem) {
        item.autosaveName = "HarmonyEye"
        let image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Harmony focus controls")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.toolTip = "Harmony — focus controls"
        item.button?.setAccessibilityLabel("Harmony focus controls")
        // AppKit owns menu tracking, highlighting and keyboard navigation.
        // Do not activate Harmony or manually pop up a menu from this button.
    }

    static func volume(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 70
    }

    /// Preserve the chosen display, including displays with negative origins.
    /// Keep the entire video reachable after resizing or disconnecting a display.
    static func videoFrame(_ frame: NSRect, visibleFrames: [NSRect], fallback: NSRect?) -> NSRect {
        guard let screen = visibleFrames.max(by: { area($0.intersection(frame)) < area($1.intersection(frame)) })
            .flatMap({ area($0.intersection(frame)) > 0 ? $0 : nil }) ?? fallback ?? visibleFrames.first,
              screen.width > 0, screen.height > 0 else { return frame }
        let width = min(frame.width, screen.width, screen.height * 16 / 9)
        let height = width * 9 / 16
        return NSRect(x: max(screen.minX, min(frame.minX, screen.maxX - width)),
                      y: max(screen.minY, min(frame.minY, screen.maxY - height)),
                      width: width, height: height)
    }

    private static func area(_ rect: NSRect) -> CGFloat {
        rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
    }
}
