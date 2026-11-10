import Cocoa

// These tests use temporary files only: no windows, permission requests, or focus.
@MainActor final class PhonePrompt {
    func activate() {}
    func present(title: String, detail: String, primary: String, secureInput: Bool,
                 cancel: Bool = true, keyboardOnly: Bool = false) async -> String? { nil }
}

@main struct SettingsLibraryRegressionTests {
    static let configuration = AppConfiguration(unlockDigest: String(repeating: "a", count: 64), approvedPaths: [])

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harmony-library-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try repairIncludedPlaylist(in: root.appendingPathComponent("included"))
        try await repairImportedPlaylist(in: root.appendingPathComponent("imported"))
        try preserveUnknownFiles(in: root.appendingPathComponent("cleanup"))
        try await editIncludedPlaylist(in: root.appendingPathComponent("included-editor"))
        try await rollbackIncludedEdit(in: root.appendingPathComponent("included-rollback"))
        try await mixAndCancelIncludedEdits(in: root.appendingPathComponent("included-mixed"))
        try rejectEscapingIncludedPlaylist(in: root.appendingPathComponent("included-unsafe"))
        print("PASS video library: corrupt-catalog repair and rollback, private imports, cancel, original and unknown-file preservation")
        print("PASS included playlist: loaded order, multi-selection, reorder, remove, save/reopen, restore and rollback")
    }

    static func check(_ value: Bool, _ message: String = "Library regression failed") {
        precondition(value, message)
    }

    static func corrupt(_ library: VideoLibrary) throws -> Data {
        let bytes = Data("{ invalid playlist, preserve these exact bytes }\n".utf8)
        try PrivateSettingsStore.write(bytes, to: library.catalog)
        return bytes
    }

    static func makeIncluded(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let player = directory.appendingPathComponent("player.html")
        try Data("<video></video>".utf8).write(to: player)
        let entries: [[String: Any]] = [
            ["file": "alpha.mp4", "title": "Alpha", "startSeconds": 120],
            ["file": "beta.mp4", "title": "Beta", "startSeconds": 60],
            ["file": "gamma.mp4", "title": "Gamma", "startSeconds": 0]
        ]
        for entry in entries {
            let name = entry["file"] as! String
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let json = try JSONSerialization.data(withJSONObject: entries)
        try (Data("window.harmonyPlaylist = ".utf8) + json + Data(";\n".utf8))
            .write(to: directory.appendingPathComponent("playlist.js"))
        return player
    }

    @MainActor static func editIncludedPlaylist(in directory: URL) async throws {
        let player = try makeIncluded(in: directory.appendingPathComponent("Bundle"))
        let library = VideoLibrary(directory: directory.appendingPathComponent("Media"))
        let model = HarmonySettingsModel(configuration: configuration, library: library, bundledPlayer: player)
        precondition(model.useIncludedVideos && model.videos.map(\.title) == ["Alpha", "Beta", "Gamma"])
        model.selectedVideos = [model.videos[2].id]
        model.moveVideos(-1)
        precondition(model.videos.map(\.title) == ["Alpha", "Gamma", "Beta"])
        model.moveVideos(from: IndexSet(integer: 0), to: 3)
        precondition(model.videos.map(\.title) == ["Gamma", "Beta", "Alpha"])
        precondition(!FileManager.default.fileExists(atPath: library.clips.path), "Reordering eagerly copied bundled videos")
        var saved = false
        model.onSave = { _ in saved = true }
        model.save()
        try await finishImport(model)
        precondition(saved)
        let persisted = try library.load()!
        precondition(persisted.map(\.title) == ["Gamma", "Beta", "Alpha"])
        precondition(persisted.map(\.startSeconds) == [0, 60, 120])
        precondition(persisted.allSatisfy { $0.file.hasPrefix("clip-") })
        let playback = try library.playerURL(bundledPlayer: player)
        let script = try String(contentsOf: playback.deletingLastPathComponent().appendingPathComponent("playlist.js"), encoding: .utf8)
        precondition(script.range(of: "Gamma")!.lowerBound < script.range(of: "Alpha")!.lowerBound)
        let reopened = HarmonySettingsModel(configuration: configuration, library: library, bundledPlayer: player)
        precondition(!reopened.useIncludedVideos && reopened.videos == persisted)
        reopened.selectedVideos = Set(reopened.videos.prefix(2).map(\.id))
        reopened.removeVideos()
        precondition(reopened.videos.map(\.title) == ["Alpha"])
        reopened.save()
        try check(library.load()!.map(\.title) == ["Alpha"])
        let restored = HarmonySettingsModel(configuration: configuration, library: library, bundledPlayer: player)
        restored.restoreIncludedVideos()
        precondition(restored.useIncludedVideos && restored.videos.map(\.title) == ["Alpha", "Beta", "Gamma"])
        restored.save()
        try check(library.load() == nil)
        try check(Data(contentsOf: player.deletingLastPathComponent().appendingPathComponent("alpha.mp4")) == Data("alpha.mp4".utf8))
    }

    @MainActor static func rollbackIncludedEdit(in directory: URL) async throws {
        let player = try makeIncluded(in: directory.appendingPathComponent("Bundle"))
        let library = VideoLibrary(directory: directory.appendingPathComponent("Media"))
        let model = HarmonySettingsModel(configuration: configuration, library: library, bundledPlayer: player)
        model.selectedVideos = [model.videos[0].id, model.videos[1].id]
        model.moveVideos(1)
        precondition(model.videos.map(\.title) == ["Gamma", "Alpha", "Beta"])
        model.onSave = { _ in throw CocoaError(.fileWriteNoPermission) }
        model.save()
        try await finishImport(model)
        try check(library.load() == nil, "Failed save replaced the bundled playlist")
        model.cancel()
        let copies = try FileManager.default.contentsOfDirectory(at: library.clips, includingPropertiesForKeys: nil)
        precondition(copies.isEmpty, "Cancelling a failed save retained prepared video copies")
    }

    static func rejectEscapingIncludedPlaylist(in directory: URL) throws {
        let player = try makeIncluded(in: directory)
        try Data("window.harmonyPlaylist = [{\"file\":\"../outside.mp4\",\"title\":\"Unsafe\"}];".utf8)
            .write(to: directory.appendingPathComponent("playlist.js"))
        do {
            _ = try VideoLibrary.includedVideos(player: player)
            preconditionFailure("Included playlist escaped its bundle")
        } catch { }
    }

    @MainActor static func mixAndCancelIncludedEdits(in directory: URL) async throws {
        let player = try makeIncluded(in: directory.appendingPathComponent("Bundle"))
        let library = VideoLibrary(directory: directory.appendingPathComponent("Media"))
        let model = HarmonySettingsModel(configuration: configuration, library: library, bundledPlayer: player)
        let ownVideo = directory.appendingPathComponent("My video.mov")
        try Data("my movie".utf8).write(to: ownVideo)
        model.addVideos([ownVideo])
        try await finishImport(model)
        precondition(model.videos.map(\.title) == ["Alpha", "Beta", "Gamma", "My video"])
        model.save()
        try await finishImport(model)
        try check(library.load()!.map(\.title) == ["Alpha", "Beta", "Gamma", "My video"])

        let cancelledLibrary = VideoLibrary(directory: directory.appendingPathComponent("Cancelled"))
        let cancelled = HarmonySettingsModel(configuration: configuration, library: cancelledLibrary, bundledPlayer: player)
        cancelled.selectedVideos = [cancelled.videos[0].id]
        cancelled.moveVideos(1)
        var finished = false
        cancelled.finish = { result in precondition(result == nil); finished = true }
        cancelled.save()
        cancelled.cancel()
        for _ in 0..<500 {
            if finished { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(finished && !cancelled.busy, "Cancellation did not finish its background cleanup")
        try check(cancelledLibrary.load() == nil)
        if FileManager.default.fileExists(atPath: cancelledLibrary.clips.path) {
            let remaining = try FileManager.default.contentsOfDirectory(atPath: cancelledLibrary.clips.path)
            precondition(remaining.isEmpty, "Cancelled playlist left video copies or partial files")
        }
    }

    @MainActor static func repairIncludedPlaylist(in directory: URL) throws {
        let library = VideoLibrary(directory: directory)
        let original = try corrupt(library)
        let model = HarmonySettingsModel(configuration: configuration, library: library)
        precondition(model.libraryNeedsRepair)
        model.restoreIncludedVideos()
        model.onSave = { _ in throw CocoaError(.fileWriteNoPermission) }
        model.save()
        try check(Data(contentsOf: library.catalog) == original, "Failed repair lost the original corrupt catalog")
        var saved: AppConfiguration?
        model.onSave = { saved = $0 }
        model.save()
        precondition(saved?.unlockDigest == configuration.unlockDigest, "Repair failed or changed the password")
        try check(library.load() == nil, "Use included playlist did not repair the catalog")
    }

    @MainActor static func finishImport(_ model: HarmonySettingsModel) async throws {
        for _ in 0..<500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Video import did not finish")
    }

    @MainActor static func repairImportedPlaylist(in directory: URL) async throws {
        let library = VideoLibrary(directory: directory)
        let originalCatalog = try corrupt(library)
        let source = directory.appendingPathComponent("my original.mov")
        let sourceBytes = Data("original movie contents".utf8)
        try sourceBytes.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        let cancelled = HarmonySettingsModel(configuration: configuration, library: library)
        cancelled.addVideos([source])
        try await finishImport(cancelled)
        precondition(!cancelled.libraryNeedsRepair && cancelled.videos.count == 1)
        let cancelledCopy = library.clips.appendingPathComponent(cancelled.videos[0].file)
        cancelled.onSave = { _ in throw CocoaError(.fileWriteNoPermission) }
        cancelled.save()
        try check(Data(contentsOf: library.catalog) == originalCatalog)
        precondition(FileManager.default.fileExists(atPath: cancelledCopy.path), "Failed save removed a draft import")
        cancelled.cancel()
        precondition(!FileManager.default.fileExists(atPath: cancelledCopy.path), "Cancel retained the draft copy")
        try check(Data(contentsOf: source) == sourceBytes, "Cancel changed the original video")

        let model = HarmonySettingsModel(configuration: configuration, library: library)
        model.addVideos([source])
        try await finishImport(model)
        let copy = library.clips.appendingPathComponent(model.videos[0].file)
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600, "Imported video is not private")
        var saved = false
        model.onSave = { config in
            precondition(config.unlockDigest == configuration.unlockDigest)
            saved = true
        }
        model.save()
        try check(saved && library.load() == model.videos, "Imported playlist did not repair the catalog")
        try check(Data(contentsOf: source) == sourceBytes)
        let sourceMode = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as! NSNumber
        precondition(sourceMode.intValue == 0o644, "Import changed original file permissions")
        let cancellation = ImportCancellation()
        cancellation.cancel()
        do {
            _ = try library.importVideo(source, cancellation: cancellation)
            preconditionFailure("Cancelled import succeeded")
        } catch let error as CocoaError { precondition(error.code == .userCancelled) }
    }

    static func preserveUnknownFiles(in directory: URL) throws {
        let library = VideoLibrary(directory: directory)
        try PrivateSettingsStore.prepareDirectory(library.clips)
        let source = directory.appendingPathComponent("source.mp4")
        try Data("source".utf8).write(to: source)
        let imported = try library.importVideo(source)
        let unknown = library.clips.appendingPathComponent("clip-family.mp4")
        let folder = library.clips.appendingPathComponent("clip-" + UUID().uuidString + ".mp4")
        let original = folder.appendingPathComponent("original.mov")
        try Data("private original".utf8).write(to: unknown)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("family movie".utf8).write(to: original)
        try library.save(nil)
        precondition(!FileManager.default.fileExists(atPath: library.clips.appendingPathComponent(imported.file).path))
        try check(Data(contentsOf: source) == Data("source".utf8))
        try check(Data(contentsOf: unknown) == Data("private original".utf8), "Cleanup removed an unknown file")
        try check(Data(contentsOf: original) == Data("family movie".utf8), "Cleanup removed a directory of original videos")
    }
}
