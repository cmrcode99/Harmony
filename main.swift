import Cocoa

// Keep process dispatch and singleton ownership separate from the app UI.
#if HARMONY_TESTING
MainActor.assumeIsolated { AppIntegrationTests.main() }
#else
if CommandLine.arguments.contains("--install-app") {
    do {
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Harmony.app")
        let backup = try AppSetup.installApp(from: Bundle.main.bundleURL, to: target, lockDirectory: AppSetup.folder)
        if let backup = backup { print("Previous app kept at: \(backup.path)") }
        exit(0)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
}
if CommandLine.arguments.contains("--is-running") {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harmony Focus")
    do {
        let probe = try HarmonyInstanceLock(directory: directory)
        exit(probe.acquire() ? 1 : 0)
    } catch { exit(2) }
}
if let index = CommandLine.arguments.firstIndex(of: "--command") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    guard let command = HarmonyCommand.parse(arguments: args) else { exit(2) }
    var rejection: String?
    guard HarmonyCommandChannel.send(command, onRejection: { rejection = $0 }, onMessage: { print($0) }) else {
        fputs((rejection ?? "Harmony did not acknowledge the command. It may still be starting; try again.") + "\n", stderr)
        exit(1)
    }
    exit(0)
}
let initialCommand: HarmonyCommand?
if let index = CommandLine.arguments.firstIndex(of: "--launch-action") {
    let args = Array(CommandLine.arguments.dropFirst(index + 1))
    guard let command = HarmonyCommand.parse(arguments: args), ["show", "lock"].contains(command.action) else {
        fputs("Invalid launch duration. Use hours 0–5 and minutes 0–59, with a total from 1 minute to 5 hours.\n", stderr)
        exit(2)
    }
    initialCommand = command
} else { initialCommand = nil }
let supervised = CommandLine.arguments.contains("--supervised")
if supervised, FocusDeadline.restored(UserDefaults.standard.double(forKey: "lockEnd"), now: Date().timeIntervalSince1970) == nil { exit(0) }
let runtimeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Harmony Focus")
let instanceLock: HarmonyInstanceLock
do { instanceLock = try HarmonyInstanceLock(directory: runtimeDirectory) }
catch { fputs("Could not acquire Harmony's instance lock.\n", stderr); exit(1) }
if supervised {
    // A newly launched login helper clears the preceding session's marker.
    UserDefaults.standard.removeObject(forKey: "sessionEnding")
    let shouldStart = FocusRecovery.waitForOwnership(isActive: {
        UserDefaults.standard.synchronize()
        return !UserDefaults.standard.bool(forKey: "sessionEnding") && FocusDeadline.restored(UserDefaults.standard.double(forKey: "lockEnd"), now: Date().timeIntervalSince1970) != nil
    }, acquire: { instanceLock.acquire() })
    guard shouldStart else { exit(0) }
} else if !instanceLock.acquire() {
    fputs("Another instance of Harmony is already running.\n", stderr)
    exit(1)
}

let app = NSApplication.shared
let delegate = App()
delegate.initialCommand = initialCommand
app.delegate = delegate
app.run()
#endif
