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
        print("PASS video library: corrupt-catalog repair and rollback, private imports, cancel, original and unknown-file preservation")
    }

    static func check(_ value: Bool, _ message: String = "Library regression failed") {
        precondition(value, message)
    }

    static func corrupt(_ library: VideoLibrary) throws -> Data {
        let bytes = Data("{ invalid playlist, preserve these exact bytes }\n".utf8)
        try PrivateSettingsStore.write(bytes, to: library.catalog)
        return bytes
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
