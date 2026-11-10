// Render the actual native settings view without opening a window or a focus session.
import Cocoa
import SwiftUI

@main struct SettingsPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("Pass an output PNG path, optionally --videos, --empty, or --light") }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.applicationIconImage = NSImage(contentsOfFile: "assets/Harmony.icns")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let config = AppConfiguration(unlockDigest: String(repeating: "a", count: 64), approvedPaths: [
            "/Applications/ChatGPT.app", "/Applications/Claude.app", "/System/Applications/Utilities/Terminal.app"
        ])
        let model = HarmonySettingsModel(configuration: config, library: VideoLibrary(directory: temporary))
        if !CommandLine.arguments.contains("--empty") {
            model.videos = [LibraryVideo(file: "clip-demo.mp4", title: "Evening rain"), LibraryVideo(file: "clip-demo2.mov", title: "My focus video")]
            model.useIncludedVideos = false
        }
        let section: SettingsSection = CommandLine.arguments.contains("--videos") ? .videos : .apps
        let view = NSHostingView(rootView: HarmonySettingsView(model: model, sessionPaused: true, section: section))
        if CommandLine.arguments.contains("--light") { view.appearance = NSAppearance(named: .aqua) }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
