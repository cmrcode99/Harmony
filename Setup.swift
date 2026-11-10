import Cocoa
import CryptoKit
import UniformTypeIdentifiers
import Darwin

struct AppConfiguration: Codable {
    var version = 1
    let unlockDigest: String
    let approvedPaths: [String]
    var approvedBundleIDs: Set<String>? = nil

    /// Validate user-edited configuration before it can enable focus restrictions.
    func validated() throws -> Self {
        let bytes = Array(unlockDigest.utf8)
        let absoluteAppPaths = approvedPaths.allSatisfy { path in
            (path as NSString).isAbsolutePath && !path.contains("\0") &&
                URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
        }
        let invalidIdentifierCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let validBundleIDs = approvedBundleIDs?.allSatisfy { identifier in
            !identifier.isEmpty && !identifier.unicodeScalars.contains(where: invalidIdentifierCharacters.contains)
        } ?? true
        guard version == 1, bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              absoluteAppPaths, validBundleIDs else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // SHA256 output is lowercase. Accept manually entered uppercase hex
        // without creating a configuration whose password can never match.
        return Self(version: version, unlockDigest: unlockDigest.lowercased(), approvedPaths: approvedPaths,
                    approvedBundleIDs: approvedBundleIDs)
    }

    var approvedIDs: Set<String> {
        (approvedBundleIDs ?? Set(approvedPaths.compactMap { Bundle(path: $0)?.bundleIdentifier }))
            .union(["local.harmony.focus", "com.apple.finder", "com.apple.systempreferences"])
    }
}

/// Persist configuration and encrypted vaults without exposing replacement
/// files, following symlinks, or removing the previous file before success.
enum PrivateSettingsStore {
    static func prepareDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func read(from url: URL) throws -> Data {
        try prepareDirectory(url.deletingLastPathComponent())
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadInvalidFileName) }
        guard fchmod(descriptor, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Use the verified descriptor so a path swap cannot redirect the read.
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        let temporary = directory.appendingPathComponent(".settings-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        // Restrict access when creating the file, before writing its first byte.
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno)) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // rename(2) atomically replaces a file (including a symlink itself),
        // without following the destination or leaving a missing-file window.
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

@MainActor enum AppSetup {
    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harmony Focus")
    }
    static var configurationURL: URL { folder.appendingPathComponent("configuration.json") }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult static func notice(_ title: String, _ detail: String, buttons: [String] = ["OK"]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func loadConfiguration(from url: URL) throws -> AppConfiguration {
        let original = try JSONDecoder().decode(AppConfiguration.self, from: PrivateSettingsStore.read(from: url))
        var config = try original.validated()
        if config.approvedBundleIDs == nil {
            config.approvedBundleIDs = config.approvedIDs
        }
        if original.unlockDigest != config.unlockDigest || original.approvedBundleIDs != config.approvedBundleIDs {
            try PrivateSettingsStore.write(JSONEncoder().encode(config), to: url)
        }
        return config
    }

    static func loadOrCreate(defaultPaths: [String]) -> AppConfiguration? {
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                return try loadConfiguration(from: configurationURL)
            } catch {
                notice("Could not load Harmony settings", "Your settings were left untouched. Ask your setup agent to repair configuration.json from your backup before starting a new session.")
                return nil
            }
        }
        guard UserDefaults.standard.double(forKey: "lockEnd") <= Date().timeIntervalSince1970 else {
            notice("Finish the previous session first", "The earlier Harmony version has an unfinished timed session. Exit it using its eye menu and password, or wait until its timer expires, before setting up this version.")
            return nil
        }
        guard notice("Set up Harmony", "Harmony shows a floating video and force-quits unapproved apps while enabled. Save your work before starting it. You choose which apps stay available.\n\nEach person gets their own 50-character exit password. Save it in a password manager or another accessible place.", buttons: ["Continue", "Cancel"]) == 0 else { return nil }
        let installed = defaultPaths.filter { FileManager.default.fileExists(atPath: $0) }
        let names = installed.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.joined(separator: ", ")
        let choice = notice("Allowed apps", "Suggested installed apps: \(names).\n\nFinder and System Settings always remain available. cmux stays unminimized when allowed.", buttons: ["Use these apps", "Choose apps…", "Cancel"])
        var paths = installed
        if choice == 1 {
            let panel = NSOpenPanel()
            panel.message = "Select every app you want available during focus mode."
            panel.prompt = "Allow selected apps"
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.applicationBundle]
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true; panel.canChooseDirectories = false
            guard panel.runModal() == .OK else { return nil }
            paths = panel.urls.map(\.path)
        } else if choice != 0 { return nil }
        paths = Array(Set(paths + ["/System/Library/CoreServices/Finder.app", "/System/Applications/System Settings.app"])).sorted()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*+-=?")
        let password = String((0..<50).map { _ in alphabet.randomElement()! })
        while true {
            let alert = NSAlert()
            alert.messageText = "Save your Harmony password"
            alert.informativeText = "This password unlocks timed sessions and the optional phone helper. Save it now. Harmony stores only its hash; it cannot show you the password again.\n\n\(password)"
            alert.addButton(withTitle: "Copy password")
            alert.addButton(withTitle: "I saved it — finish setup")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
            case .alertSecondButtonReturn:
                let config = AppConfiguration(unlockDigest: digest(password), approvedPaths: paths,
                                                 approvedBundleIDs: Set(paths.compactMap { Bundle(path: $0)?.bundleIdentifier }))
                do {
                    try PrivateSettingsStore.write(JSONEncoder().encode(config.validated()), to: configurationURL)
                    notice("Setup saved", "Start Harmony again when you are ready. In System Settings, allow Harmony to control apps so window minimization works. Screen Recording is needed only for the optional phone helper.")
                    return config
                } catch { notice("Setup could not be saved", error.localizedDescription); return nil }
            default: return nil
            }
        }
    }

    /// Copy first, then hold the same lock as the app for the entire swap.
    /// Old installs remain recoverable and failed swaps restore them.
    nonisolated static func installApp(from source: URL, to destination: URL, lockDirectory: URL) throws -> URL? {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".harmony-install-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("Harmony.app")
        try fm.copyItem(at: source, to: copy)
        let lock = try HarmonyInstanceLock(directory: lockDirectory)
        guard lock.acquire() else {
            throw NSError(domain: "HarmonyInstall", code: 1, userInfo: [NSLocalizedDescriptionKey: "Harmony started during installation. Exit it and try again; the existing app was left unchanged."])
        }
        defer { withExtendedLifetime(lock) {} }
        var backup: URL?
        if fm.fileExists(atPath: destination.path) {
            let folder = parent.appendingPathComponent(".harmony-previous-" + UUID().uuidString)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            backup = folder.appendingPathComponent("Harmony.app")
            try fm.moveItem(at: destination, to: backup!)
        }
        do { try fm.moveItem(at: copy, to: destination) }
        catch {
            if let backup = backup { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        return backup
    }

    static func configurePhone(_ config: AppConfiguration) {
        let passwordAlert = NSAlert()
        passwordAlert.messageText = "Set up iPhone entry"
        passwordAlert.informativeText = "Enter your long Harmony password. This encrypts the existing Screen Time code; it does not change your phone's settings."
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        passwordAlert.accessoryView = passwordField
        passwordAlert.addButton(withTitle: "Continue"); passwordAlert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard passwordAlert.runModal() == .alertFirstButtonReturn else { return }
        let password = passwordField.stringValue
        guard digest(password) == config.unlockDigest else { notice("Password did not match", "Nothing was changed."); return }
        let alert = NSAlert()
        alert.messageText = "Your existing Screen Time code"
        alert.informativeText = "Enter the same four-digit code twice. Configure Screen Time and iPhone Mirroring yourself first. Harmony only keeps an encrypted copy."
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        first.placeholderString = "Existing four-digit code"; second.placeholderString = "Confirm code"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        view.addSubview(first); view.addSubview(second); alert.accessoryView = view
        alert.addButton(withTitle: "Save encrypted code"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pin = first.stringValue
        guard pin == second.stringValue, pin.utf8.count == 4,
              pin.utf8.allSatisfy({ (48...57).contains($0) }) else { notice("Codes did not match", "Nothing was changed. Use the same four digits in both fields."); return }
        do {
            let vault = try PhoneBridge.seal(pin, password: password)
            let target = folder.appendingPathComponent("phone-vault.json")
            try PrivateSettingsStore.write(JSONEncoder().encode(vault), to: target)
            notice("Phone helper configured", "Start Harmony, open iPhone Mirroring to the empty Screen Time passcode prompt, then choose Enter phone passcode in the eye menu.")
        } catch { notice("Could not save phone setup", error.localizedDescription) }
    }
}
