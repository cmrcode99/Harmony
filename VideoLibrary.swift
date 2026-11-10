import Foundation

struct LibraryVideo: Codable, Equatable, Identifiable, Sendable {
    let file: String
    let title: String
    var startSeconds: Double = 0
    var id: String { file }
}

final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CocoaError(.userCancelled) }
    }
}

/// User videos live outside the signed app. Only Harmony's copies are removed.
struct VideoLibrary: Sendable {
    let directory: URL
    var catalog: URL { directory.appendingPathComponent("playlist.json") }
    var clips: URL { directory.appendingPathComponent("Clips", isDirectory: true) }
    static var user: Self { Self(directory: AppSetup.folder.appendingPathComponent("Media", isDirectory: true)) }
    static let extensions = Set(["mp4", "m4v", "mov"])

    func validate(_ videos: [LibraryVideo]) throws {
        guard videos.count <= 1024, Set(videos.map(\.file)).count == videos.count,
              videos.allSatisfy({ video in
                  video.file.hasPrefix("clip-") && !video.file.contains("/") && !video.file.contains("\\") &&
                  video.file == URL(fileURLWithPath: video.file).lastPathComponent &&
                  Self.extensions.contains(URL(fileURLWithPath: video.file).pathExtension.lowercased()) &&
                  video.startSeconds.isFinite && video.startSeconds >= 0
              }) else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// nil keeps the bundled playlist; an empty list intentionally has no videos.
    func load() throws -> [LibraryVideo]? {
        guard FileManager.default.fileExists(atPath: catalog.path) else { return nil }
        let videos = try JSONDecoder().decode([LibraryVideo].self, from: PrivateSettingsStore.read(from: catalog))
        try validate(videos)
        return videos
    }

    func save(_ videos: [LibraryVideo]?, prune: Bool = true) throws {
        if let videos {
            try validate(videos)
            try PrivateSettingsStore.write(JSONEncoder().encode(videos), to: catalog)
        } else if FileManager.default.fileExists(atPath: catalog.path) {
            try FileManager.default.removeItem(at: catalog)
        }
        if prune { removeUnused(keeping: videos ?? []) }
    }

    private var ownsClipsDirectory: Bool {
        let fm = FileManager.default
        return [directory, clips].allSatisfy { url in
            (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
        }
    }

    func removeUnused(keeping videos: [LibraryVideo]) {
        guard ownsClipsDirectory else { return }
        let keep = Set(videos.map(\.file))
        for file in (try? FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasPrefix("clip-") && !keep.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func importVideo(_ source: URL, cancellation: ImportCancellation = ImportCancellation()) throws -> LibraryVideo {
        guard source.isFileURL, Self.extensions.contains(source.pathExtension.lowercased()) else {
            throw NSError(domain: "HarmonyVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an MP4, M4V, or MOV video."])
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? 0) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try cancellation.check()
        try PrivateSettingsStore.prepareDirectory(clips)
        let name = "clip-" + UUID().uuidString + "." + source.pathExtension.lowercased()
        let destination = clips.appendingPathComponent(name)
        let temporary = clips.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        while true {
            try cancellation.check()
            guard let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try cancellation.check()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return LibraryVideo(file: name, title: source.deletingPathExtension().lastPathComponent)
    }

    func discard(_ videos: [LibraryVideo]) {
        guard ownsClipsDirectory, (try? validate(videos)) != nil else { return }
        for video in videos { try? FileManager.default.removeItem(at: clips.appendingPathComponent(video.file)) }
    }

    func playerURL(bundledPlayer: URL) throws -> URL {
        guard let videos = try load() else { return bundledPlayer }
        try PrivateSettingsStore.prepareDirectory(directory)
        let html = directory.appendingPathComponent("player.html")
        try PrivateSettingsStore.write(Data(contentsOf: bundledPlayer), to: html)
        let entries: [[String: Any]] = videos.map { ["file": "Clips/" + $0.file, "title": $0.title, "startSeconds": $0.startSeconds] }
        let json = try JSONSerialization.data(withJSONObject: entries)
        var script = Data("window.harmonyPlaylist = ".utf8)
        script.append(json); script.append(Data(";\n".utf8))
        try PrivateSettingsStore.write(script, to: directory.appendingPathComponent("playlist.js"))
        return html
    }
}
