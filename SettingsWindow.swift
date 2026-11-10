import Cocoa
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: Equatable {
    case apps, videos

    static var launchSelection: Self? {
        if CommandLine.arguments.contains("--settings-apps") { return .apps }
        if CommandLine.arguments.contains("--settings-videos") { return .videos }
        return nil
    }

    var finderDirectory: URL {
        if self == .apps { return URL(fileURLWithPath: "/Applications", isDirectory: true) }
        let manager = FileManager.default
        let movies = manager.urls(for: .moviesDirectory, in: .userDomainMask).first!
        if manager.fileExists(atPath: movies.path) { return movies }
        return manager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? manager.homeDirectoryForCurrentUser
    }
}

@MainActor final class HarmonySettingsModel: ObservableObject {
    static let fixedApps = ["/System/Library/CoreServices/Finder.app", "/System/Applications/System Settings.app"]
    let original: AppConfiguration
    let library: VideoLibrary
    @Published var appPaths: [String]
    @Published var videos: [LibraryVideo] = []
    @Published var useIncludedVideos = true
    @Published var selectedApp: String?
    @Published var selectedVideo: String?
    @Published var busy = false
    @Published var message = ""
    var onSave: ((AppConfiguration) throws -> Void)?
    var finish: ((AppConfiguration?) -> Void)?
    private var imports: [LibraryVideo] = []
    private let cancellation = ImportCancellation()
    private var closed = false
    @Published private(set) var libraryNeedsRepair = false

    init(configuration: AppConfiguration, library: VideoLibrary = .user) {
        original = configuration
        self.library = library
        appPaths = Array(Set(configuration.approvedPaths + Self.fixedApps)).sorted()
        do {
            if let saved = try library.load() { videos = saved; useIncludedVideos = false }
        } catch { libraryNeedsRepair = true; message = "The video library could not be read. Add videos to replace it, or use the included playlist." }
    }

    func addApps(_ urls: [URL]) {
        guard !closed else { return }
        var rejected = false
        var ids = Set(appPaths.compactMap { Bundle(path: $0)?.bundleIdentifier })
        for url in urls {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.pathExtension.lowercased() == "app", let bundle = Bundle(url: resolved),
                  let identifier = bundle.bundleIdentifier else { rejected = true; continue }
            guard !ids.contains(identifier) else { continue }
            ids.insert(identifier); appPaths.append(resolved.path)
        }
        appPaths.sort { URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1).lastPathComponent) == .orderedAscending }
        message = rejected ? "Choose application bundles (.app), or drag them here from Applications." : ""
    }

    func removeApp() {
        guard let selectedApp, !Self.fixedApps.contains(selectedApp) else { return }
        appPaths.removeAll { $0 == selectedApp }; self.selectedApp = nil
    }

    func addVideos(_ urls: [URL]) {
        guard !closed, !busy, !urls.isEmpty else { return }
        guard videos.count + urls.count <= 1024 else { message = "A playlist can hold up to 1024 videos."; return }
        busy = true; message = "Copying videos into Harmony…"
        let library = library, cancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var imported: [LibraryVideo] = []
            var failure: String?
            do {
                for url in urls { imported.append(try library.importVideo(url, cancellation: cancellation)) }
            } catch { failure = error.localizedDescription }
            let completed = imported, errorMessage = failure
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { library.discard(completed); return }
                self.busy = false
                if !completed.isEmpty { self.libraryNeedsRepair = false; self.useIncludedVideos = false; self.videos.append(contentsOf: completed); self.imports.append(contentsOf: completed) }
                self.message = errorMessage ?? ""
            }
        }
    }

    func removeVideo() {
        guard let selectedVideo else { return }
        videos.removeAll { $0.id == selectedVideo }; self.selectedVideo = nil
    }

    func moveVideo(_ offset: Int) {
        guard let selectedVideo, let index = videos.firstIndex(where: { $0.id == selectedVideo }),
              videos.indices.contains(index + offset) else { return }
        videos.swapAt(index, index + offset)
    }

    func restoreIncludedVideos() {
        libraryNeedsRepair = false; useIncludedVideos = true; videos = []; selectedVideo = nil; message = ""
    }

    func save() {
        guard !closed, !busy, !libraryNeedsRepair else { return }
        do {
            let ids = Set(appPaths.compactMap { Bundle(path: $0)?.bundleIdentifier })
            let configuration = try AppConfiguration(unlockDigest: original.unlockDigest, approvedPaths: appPaths, approvedBundleIDs: ids).validated()
            try library.validate(videos)
            // Preserve the exact catalog, including an invalid playlist that
            // the user has explicitly chosen to replace. Decoding it here would
            // make the offered repair actions fail on Save every time.
            let previous = FileManager.default.fileExists(atPath: library.catalog.path)
                ? try PrivateSettingsStore.read(from: library.catalog) : nil
            let updated: [LibraryVideo]? = useIncludedVideos ? nil : videos
            try library.save(updated, prune: false)
            do { try onSave?(configuration) }
            catch {
                if let previous { try? PrivateSettingsStore.write(previous, to: library.catalog) }
                else { try? library.save(nil, prune: false) }
                throw error
            }
            library.removeUnused(keeping: updated ?? [])
            closed = true; finish?(configuration)
        } catch { message = "Could not save settings: " + error.localizedDescription }
    }

    func cancel() {
        guard !closed else { return }
        closed = true; cancellation.cancel(); library.discard(imports); finish?(nil)
    }

    func chooseApps() {
        let panel = NSOpenPanel()
        panel.title = "Add allowed applications"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addApps(panel.urls) }
    }

    func chooseVideos() {
        let panel = NSOpenPanel()
        panel.title = "Add your videos"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addVideos(panel.urls) }
    }
}

private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: URL] = [:]
    func append(_ url: URL, at index: Int) { lock.lock(); values[index] = url; lock.unlock() }
    func all() -> [URL] { lock.lock(); defer { lock.unlock() }; return values.keys.sorted().compactMap { values[$0] } }
}

private struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(prominent ? Color.teal : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
}

@MainActor struct HarmonySettingsView: View {
    @ObservedObject var model: HarmonySettingsModel
    var firstRun = false
    var sessionPaused = false
    var section: SettingsSection? = nil
    @State private var appsTargeted = false
    @State private var videosTargeted = false

    private func receive(_ providers: [NSItemProvider], apps: Bool) -> Bool {
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !supported.isEmpty, !model.busy else { return false }
        let group = DispatchGroup(), urls = DroppedURLs()
        for (index, provider) in supported.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL { urls.append(url, at: index) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url, at: index) }
            }
        }
        group.notify(queue: .main) {
            if apps { model.addApps(urls.all()) } else { model.addVideos(urls.all()) }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(firstRun ? "Make room for focus" : "Harmony settings").font(.title2.bold())
                    Text(section == .apps ? "Drag apps from Finder into Allowed apps." : (section == .videos ? "Drag your videos from Finder into Your videos." : "Choose your apps and videos. Your agent can help with the rest.")).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Allowed apps", systemImage: "app.badge.checkmark").font(.headline)
                    Text("Drag apps here from Applications. Other apps are force-quit during focus.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.appPaths, id: \.self) { path in
                                Button { model.selectedApp = path } label: {
                                    HStack(spacing: 10) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 25, height: 25)
                                        Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).lineLimit(1)
                                        Spacer()
                                        if HarmonySettingsModel.fixedApps.contains(path) { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Always allowed") }
                                    }.padding(9).contentShape(Rectangle())
                                        .background(RoundedRectangle(cornerRadius: 6).fill(model.selectedApp == path ? Color.teal.opacity(0.2) : Color.clear))
                                }.buttonStyle(.plain)
                            }
                        }.padding(6)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke((appsTargeted || section == .apps) ? Color.teal : Color.secondary.opacity(0.2), lineWidth: (appsTargeted || section == .apps) ? 3 : 1))
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $appsTargeted) { receive($0, apps: true) }
                    HStack {
                        Button("Add apps…", action: model.chooseApps)
                        Button("Remove", action: model.removeApp).disabled(model.selectedApp == nil || HarmonySettingsModel.fixedApps.contains(model.selectedApp ?? ""))
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your videos", systemImage: "play.rectangle").font(.headline)
                    Text("Drop MP4, M4V, or MOV files. Harmony keeps a copy; your originals stay where they are.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ZStack {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(model.videos) { video in
                                    Button { model.selectedVideo = video.id } label: {
                                        HStack {
                                            Image(systemName: "film").foregroundStyle(.teal)
                                            Text(video.title).lineLimit(1)
                                            Spacer()
                                        }.padding(11).contentShape(Rectangle())
                                            .background(RoundedRectangle(cornerRadius: 6).fill(model.selectedVideo == video.id ? Color.teal.opacity(0.2) : Color.clear))
                                    }.buttonStyle(.plain)
                                }
                            }.padding(6)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                        if model.videos.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc").font(.title)
                                Text(model.useIncludedVideos ? "Drop your videos here" : "No videos yet").font(.headline)
                                Text("Drop videos here, or add them later.").font(.callout)
                            }.foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke((videosTargeted || section == .videos) ? Color.teal : Color.secondary.opacity(0.2), lineWidth: (videosTargeted || section == .videos) ? 3 : 1))
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $videosTargeted) { receive($0, apps: false) }
                    HStack {
                        Button("Add videos…", action: model.chooseVideos)
                        Button("Remove", action: model.removeVideo).disabled(model.selectedVideo == nil)
                        Spacer()
                        Button { model.moveVideo(-1) } label: { Image(systemName: "arrow.up") }.help("Move earlier").accessibilityLabel("Move video earlier").disabled(model.selectedVideo == nil || model.videos.first?.id == model.selectedVideo)
                        Button { model.moveVideo(1) } label: { Image(systemName: "arrow.down") }.help("Move later").accessibilityLabel("Move video later").disabled(model.selectedVideo == nil || model.videos.last?.id == model.selectedVideo)
                    }
                    Button("Use included playlist", action: model.restoreIncludedVideos)
                        .buttonStyle(.link)
                }
            }.frame(minHeight: 260).disabled(model.busy)
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text(model.message).foregroundStyle(.secondary) }
            } else if !model.message.isEmpty {
                Text(model.message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(firstRun ? "Setup does not start focus. Next, save your recovery password." : (sessionPaused ? "Focus is paused and resumes when you close settings." : "Changes apply after you save. Phone setup is optional.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button(firstRun ? "Continue" : "Save changes", action: model.save).keyboardShortcut(.defaultAction).buttonStyle(SettingsButtonStyle(prominent: true)).disabled(model.busy || model.libraryNeedsRepair)
            }
        }.padding(24).frame(minWidth: 740, minHeight: 470)
            .buttonStyle(SettingsButtonStyle()).tint(.teal)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor final class HarmonySettingsWindow: NSObject, NSWindowDelegate {
    let model: HarmonySettingsModel
    let window: NSWindow
    private var result: AppConfiguration?
    private let section: SettingsSection?
    private let revealFinder: Bool

    init(configuration: AppConfiguration, firstRun: Bool = false, sessionPaused: Bool = false, library: VideoLibrary = .user,
         section: SettingsSection? = nil, revealFinder: Bool = false,
         onSave: ((AppConfiguration) throws -> Void)? = nil) {
        self.section = section
        self.revealFinder = revealFinder
        model = HarmonySettingsModel(configuration: configuration, library: library)
        model.onSave = onSave
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = firstRun ? "Welcome to Harmony" : (section == .apps ? "Allowed Apps — Harmony" : (section == .videos ? "Allowed Videos — Harmony" : "Harmony Settings"))
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 520)
        window.contentView = NSHostingView(rootView: HarmonySettingsView(model: model, firstRun: firstRun, sessionPaused: sessionPaused, section: section))
        window.delegate = self
        model.finish = { [weak self] configuration in
            self?.result = configuration
            NSApp.stopModal()
            self?.window.orderOut(nil)
        }
    }

    func run() -> AppConfiguration? {
        window.center()
        if revealFinder, let section {
            NSWorkspace.shared.open(section.finderDirectory)
            if let screen = NSScreen.main {
                var frame = window.frame
                frame.origin.x = max(screen.visibleFrame.minX + 20, screen.visibleFrame.maxX - frame.width - 24)
                window.setFrame(frame, display: false)
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return result
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model.cancel(); return true }
}
