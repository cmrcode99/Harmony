import Cocoa
import CryptoKit
import UniformTypeIdentifiers

struct AppConfiguration: Codable {
    var version = 1
    let unlockDigest: String
    let approvedPaths: [String]
    var approvedBundleIDs: Set<String>? = nil

    var approvedIDs: Set<String> {
        (approvedBundleIDs ?? Set(approvedPaths.compactMap { Bundle(path: $0)?.bundleIdentifier }))
            .union(["local.harmony.focus", "com.apple.finder", "com.apple.systempreferences"])
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

    static func loadOrCreate(defaultPaths: [String]) -> AppConfiguration? {
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                var config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: configurationURL))
                guard config.version == 1, config.unlockDigest.count == 64,
                      config.unlockDigest.allSatisfy({ $0.isHexDigit }) else { throw CocoaError(.fileReadCorruptFile) }
                if config.approvedBundleIDs == nil {
                    config.approvedBundleIDs = config.approvedIDs
                    try JSONEncoder().encode(config).write(to: configurationURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
                }
                return config
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
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                    try JSONEncoder().encode(config).write(to: configurationURL, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
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
            try JSONEncoder().encode(vault).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            notice("Phone helper configured", "Start Harmony, open iPhone Mirroring to the empty Screen Time passcode prompt, then choose Enter phone passcode in the eye menu.")
        } catch { notice("Could not save phone setup", error.localizedDescription) }
    }
}
