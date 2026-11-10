import Cocoa
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: Hashable {
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
    private let includedVideos: [LibraryVideo]
    private let includedSources: [String: URL]
    @Published var appPaths: [String]
    @Published var videos: [LibraryVideo] = []
    @Published var useIncludedVideos = true
    @Published var selectedApps: Set<String> = []
    @Published var selectedVideos: Set<String> = []
    @Published var busy = false
    @Published var message = ""
    var onSave: ((AppConfiguration) throws -> Void)?
    var finish: ((AppConfiguration?) -> Void)?
    private var imports: [LibraryVideo] = []
    private let cancellation = ImportCancellation()
    private var closed = false
    @Published private(set) var libraryNeedsRepair = false

    init(configuration: AppConfiguration, library: VideoLibrary = .user,
         bundledPlayer: URL? = Bundle.main.url(forResource: "player", withExtension: "html")) {
        original = configuration
        self.library = library
        var included: [(video: LibraryVideo, url: URL)] = []
        var includedError: String?
        do { included = try VideoLibrary.includedVideos(player: bundledPlayer) }
        catch { includedError = "The included playlist could not be read. You can add your own videos." }
        includedVideos = included.map(\.video)
        includedSources = Dictionary(uniqueKeysWithValues: included.map { ($0.video.id, $0.url) })
        videos = includedVideos
        appPaths = Array(Set(configuration.approvedPaths + Self.fixedApps)).sorted()
        do {
            if let saved = try library.load() { videos = saved; useIncludedVideos = false }
            else if let includedError { message = includedError }
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

    var removableSelectedApps: Set<String> {
        selectedApps.intersection(appPaths).subtracting(Self.fixedApps)
    }

    func removeApps() {
        guard !closed, !busy else { return }
        let removed = removableSelectedApps
        appPaths.removeAll { removed.contains($0) }
        selectedApps.removeAll()
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
                guard let self else { library.discard(completed); return }
                guard !self.closed else {
                    library.discard(completed); self.busy = false; self.finish?(nil); return
                }
                self.busy = false
                if !completed.isEmpty { self.libraryNeedsRepair = false; self.useIncludedVideos = false; self.videos.append(contentsOf: completed); self.imports.append(contentsOf: completed) }
                self.message = errorMessage ?? ""
            }
        }
    }

    func removeVideos() {
        guard !closed, !busy, !selectedVideos.isEmpty else { return }
        videos.removeAll { selectedVideos.contains($0.id) }
        selectedVideos.removeAll()
        libraryNeedsRepair = false
        useIncludedVideos = false
    }

    func canMoveVideos(_ offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { return false }
        let indices = videos.indices.filter { selectedVideos.contains(videos[$0].id) }
        guard let first = indices.first, let last = indices.last else { return false }
        return offset < 0 ? first > 0 : last < videos.count - 1
    }

    func moveVideos(_ offset: Int) {
        guard !closed, !busy, canMoveVideos(offset) else { return }
        let indices = videos.indices.filter { selectedVideos.contains(videos[$0].id) }
        for index in offset < 0 ? indices : Array(indices.reversed()) {
            videos.swapAt(index, index + offset)
        }
        libraryNeedsRepair = false
        useIncludedVideos = false
    }

    func moveVideos(from source: IndexSet, to destination: Int) {
        guard !closed, !busy else { return }
        videos.move(fromOffsets: source, toOffset: destination)
        libraryNeedsRepair = false
        useIncludedVideos = false
    }

    func restoreIncludedVideos() {
        guard !closed, !busy else { return }
        libraryNeedsRepair = false; useIncludedVideos = true; videos = includedVideos; selectedVideos.removeAll(); message = ""
    }

    func save() {
        guard !closed, !busy, !libraryNeedsRepair else { return }
        guard !useIncludedVideos, videos.contains(where: { includedSources[$0.id] != nil }) else {
            commit(useIncludedVideos ? nil : videos)
            return
        }
        // A customized default playlist gets private copies only when saved.
        // Copying happens off the main thread so tabs and Cancel remain responsive.
        busy = true; message = "Preparing your playlist…"
        let desired = videos, sources = includedSources, library = library, cancellation = cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resolved: [LibraryVideo] = [], copies: [LibraryVideo] = []
            var failure: String?
            do {
                for video in desired {
                    if let source = sources[video.id] {
                        let imported = try library.importVideo(source, cancellation: cancellation)
                        let copy = LibraryVideo(file: imported.file, title: video.title, startSeconds: video.startSeconds)
                        copies.append(copy); resolved.append(copy)
                    } else { resolved.append(video) }
                }
            } catch { failure = error.localizedDescription }
            let result = resolved, imported = copies, errorMessage = failure
            DispatchQueue.main.async { [weak self] in
                guard let self else { library.discard(imported); return }
                guard !self.closed else {
                    library.discard(imported); self.busy = false; self.finish?(nil); return
                }
                self.busy = false
                if let errorMessage {
                    library.discard(imported)
                    self.message = "Could not prepare the playlist: " + errorMessage
                    return
                }
                self.videos = result; self.selectedVideos.removeAll(); self.imports.append(contentsOf: imported)
                self.commit(result)
            }
        }
    }

    private func commit(_ updated: [LibraryVideo]?) {
        do {
            let ids = Set(appPaths.compactMap { Bundle(path: $0)?.bundleIdentifier })
            let configuration = try AppConfiguration(unlockDigest: original.unlockDigest, approvedPaths: appPaths, approvedBundleIDs: ids).validated()
            if let updated { try library.validate(updated) }
            // Preserve the exact catalog, including an invalid playlist that
            // the user has explicitly chosen to replace. Decoding it here would
            // make the offered repair actions fail on Save every time.
            let previous = FileManager.default.fileExists(atPath: library.catalog.path)
                ? try PrivateSettingsStore.read(from: library.catalog) : nil
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
        closed = true; cancellation.cancel(); library.discard(imports)
        if !busy { finish?(nil) }
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

private struct SettingsWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct SettingsGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
        } else if #available(macOS 26.0, *) {
            content.foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

private struct SettingsControlStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent).foregroundStyle(Color.white) }
            else { content.buttonStyle(.glass).foregroundStyle(colorScheme == .dark ? Color.white : Color.black) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

@MainActor struct HarmonySettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: HarmonySettingsModel
    var firstRun = false
    var sessionPaused = false
    var section: SettingsSection? = nil
    @State private var appsTargeted = false
    @State private var videosTargeted = false
    @State private var selectedSection: SettingsSection?

    private var selection: SettingsSection { selectedSection ?? section ?? .apps }

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

    private var sectionBinding: Binding<SettingsSection?> {
        Binding(get: { selection }, set: { if let section = $0 { selectedSection = section } })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 30, height: 30)
                Text("Harmony").font(.system(size: 14, weight: .semibold))
            }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 23)
            List(selection: sectionBinding) {
                Label("Allowed apps", systemImage: "square.grid.2x2").tag(SettingsSection.apps)
                Label("Allowed videos", systemImage: "play.rectangle").tag(SettingsSection.videos)
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .font(.system(size: 13)).frame(height: 110)
            Spacer()
            if firstRun {
                Text("SETUP").font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(.secondary).padding(10)
            }
        }.padding(12).frame(width: 190)
            .modifier(SettingsGlassSurface(radius: 16)).padding(8)
    }

    private var appList: some View {
        List(selection: $model.selectedApps) {
            ForEach(model.appPaths, id: \.self) { path in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 24, height: 24)
                    Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    if HarmonySettingsModel.fixedApps.contains(path) {
                        Text("Always allowed").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .tag(path)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onDeleteCommand(perform: model.removeApps)
    }

    private var videoList: some View {
        ZStack {
            List(selection: $model.selectedVideos) {
                ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                    HStack(spacing: 10) {
                        Text(String(index + 1)).font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 18)
                        Image(systemName: "film").foregroundStyle(.secondary)
                        Text(video.title).lineLimit(1).help(video.title)
                        Spacer()
                    }.padding(.vertical, 7).contentShape(Rectangle())
                        .tag(video.id).listRowSeparator(.hidden)
                }
                .onMove { model.moveVideos(from: $0, to: $1) }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .onDeleteCommand(perform: model.removeVideos)
            if model.videos.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "play.rectangle").font(.system(size: 28, weight: .light))
                    Text(model.useIncludedVideos ? "No included videos in this build" : "No videos added").font(.system(size: 13, weight: .medium))
                    Text("Add your own videos anytime.").font(.caption)
                }.foregroundStyle(.secondary).allowsHitTesting(false)
            }
        }
    }

    private var libraryPanel: some View {
        VStack(spacing: 0) {
            Group {
                if selection == .apps { appList } else { videoList }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "plus.circle.dashed")
                Text(selection == .apps ? "Drop apps here from Applications" : "Drop videos to add · Drag rows to reorder")
                    .font(.caption)
                Spacer()
            }.foregroundStyle((selection == .apps ? appsTargeted : videosTargeted) ? Color.accentColor : (colorScheme == .dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6)))
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.primary.opacity(0.025))
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .modifier(SettingsGlassSurface(radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke((selection == .apps ? appsTargeted : videosTargeted) ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: (selection == .apps ? appsTargeted : videosTargeted) ? 2 : 1))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: selection == .apps ? $appsTargeted : $videosTargeted) {
            receive($0, apps: selection == .apps)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if selection == .apps {
                Button("Add apps", action: model.chooseApps)
                Button("Remove apps", action: model.removeApps)
                    .disabled(model.removableSelectedApps.isEmpty)
            } else {
                Button("Add videos", action: model.chooseVideos)
                Button("Remove videos", action: model.removeVideos).disabled(model.selectedVideos.isEmpty)
                ControlGroup {
                    Button { model.moveVideos(-1) } label: { Image(systemName: "arrow.up") }
                        .help("Move earlier").accessibilityLabel("Move video earlier")
                        .disabled(!model.canMoveVideos(-1))
                    Button { model.moveVideos(1) } label: { Image(systemName: "arrow.down") }
                        .help("Move later").accessibilityLabel("Move video later")
                        .disabled(!model.canMoveVideos(1))
                }.fixedSize()
                Spacer()
                Button("Use included playlist", action: model.restoreIncludedVideos)
                    .buttonStyle(.link).font(.caption).disabled(model.useIncludedVideos && !model.libraryNeedsRepair)
            }
            if selection == .apps { Spacer() }
        }.controlSize(.regular).modifier(SettingsControlStyle())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(selection == .apps ? "Allowed apps" : "Allowed videos")
                                .font(.system(size: 21, weight: .semibold))
                            Spacer()
                            Text(selection == .apps ? "\(model.appPaths.count) apps" : "\(model.videos.count) videos" + (model.useIncludedVideos ? " · Included" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(selection == .apps ? "Other apps are force-quit during focus." : "Harmony copies your videos. Your originals stay untouched.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    libraryPanel
                    actions
                }.padding(24).disabled(model.busy)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.busy || !model.message.isEmpty {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.message).font(.callout).foregroundStyle(model.busy ? Color.secondary : .red)
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            HStack(spacing: 10) {
                Text(firstRun ? "Next: save your recovery password." : (sessionPaused ? "Focus is paused until you close settings." : "Changes apply when you save."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                    .modifier(SettingsControlStyle())
                Button(firstRun ? "Continue" : "Save changes", action: model.save)
                    .keyboardShortcut(.defaultAction).modifier(SettingsControlStyle(prominent: true))
                    .disabled(model.busy || model.libraryNeedsRepair)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(minWidth: 740, minHeight: 440).padding(.top, 24)
            .background(SettingsWindowMaterial().ignoresSafeArea())
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = firstRun ? "Welcome to Harmony" : (section == .apps ? "Allowed Apps — Harmony" : (section == .videos ? "Allowed Videos — Harmony" : "Harmony Settings"))
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 470)
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
