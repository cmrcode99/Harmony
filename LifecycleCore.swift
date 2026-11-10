import Foundation
import Darwin
import CoreServices

struct HarmonyDuration: Equatable {
    let hours: Int
    let minutes: Int
    var seconds: TimeInterval { Double(hours * 3600 + minutes * 60) }

    init?(hours: Int, minutes: Int = 0) {
        guard (0...5).contains(hours), (0...59).contains(minutes),
              hours * 60 + minutes > 0, hours * 60 + minutes <= 300 else { return nil }
        self.hours = hours; self.minutes = minutes
    }

    static func parse(hours: String, minutes: String?) -> Self? {
        guard ["0", "1", "2", "3", "4", "5"].contains(hours), let h = Int(hours) else { return nil }
        guard let raw = minutes else { return h > 0 ? Self(hours: h) : nil }
        guard (1...2).contains(raw.utf8.count), raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let m = Int(raw) else { return nil }
        return Self(hours: h, minutes: m)
    }
}

struct HarmonyCommand: Equatable {
    let action: String
    let hours: Int?
    let minutes: Int

    init(action: String, hours: Int?, minutes: Int = 0) {
        self.action = action; self.hours = hours; self.minutes = minutes
    }

    func rejection(isLocked: Bool, promptBusy: Bool, focusEnabled: Bool) -> String? {
        if action == "show" || action == "lock" {
            return "Another instance of Harmony is already running."
        }
        if action == "exit", isLocked {
            return "A timed Harmony session is active. Use the eye menu to exit with your password."
        }
        if action == "phone", !focusEnabled {
            return "Harmony focus mode has ended. Exit Harmony, then start a new session before using phone entry."
        }
        if action == "extend" {
            guard isLocked, focusEnabled else {
                return "Only an active timed Harmony session can be extended."
            }
            if promptBusy {
                return "Finish or cancel the current password or phone-entry prompt before extending the timer."
            }
        }
        return nil
    }

    static func parse(action: String, hours: String? = nil, minutes: String? = nil) -> HarmonyCommand? {
        if action == "lock" || action == "extend" {
            guard let hours = hours, let duration = HarmonyDuration.parse(hours: hours, minutes: minutes) else { return nil }
            return HarmonyCommand(action: action, hours: duration.hours, minutes: duration.minutes)
        }
        guard hours == nil, minutes == nil, ["show", "unhide", "hide", "exit", "phone"].contains(action) else { return nil }
        return HarmonyCommand(action: action, hours: nil)
    }

    static func parse(arguments: [String]) -> HarmonyCommand? {
        guard let action = arguments.first, arguments.count <= 3 else { return nil }
        return parse(action: action, hours: arguments.count > 1 ? arguments[1] : nil,
                     minutes: arguments.count > 2 ? arguments[2] : nil)
    }
}

enum FocusDeadline {
    struct Extension {
        let wallDeadline: TimeInterval
        let uptimeDeadline: TimeInterval
        let remaining: TimeInterval
    }
    static let maximumDuration: TimeInterval = 5 * 3600
    static func restored(_ deadline: TimeInterval, now: TimeInterval) -> TimeInterval? {
        guard deadline.isFinite, now.isFinite, deadline > now else { return nil }
        return min(deadline, now + maximumDuration)
    }
    static func remaining(wallDeadline: TimeInterval, uptimeDeadline: TimeInterval?, now: TimeInterval, uptime: TimeInterval) -> TimeInterval {
        guard wallDeadline.isFinite, now.isFinite else { return 0 }
        let wallRemaining = max(0, wallDeadline - now)
        guard let end = uptimeDeadline, end.isFinite, uptime.isFinite else { return wallRemaining }
        // Wall time includes sleep; monotonic time prevents clock changes extending a run.
        return min(wallRemaining, max(0, end - uptime))
    }

    static func extending(wallDeadline: TimeInterval, uptimeDeadline: TimeInterval?, hours: Int, minutes: Int = 0,
                          now: TimeInterval, uptime: TimeInterval) -> Extension? {
        guard let target = HarmonyDuration(hours: hours, minutes: minutes), now.isFinite, uptime.isFinite else { return nil }
        if let end = uptimeDeadline, !end.isFinite { return nil }
        let current = remaining(wallDeadline: wallDeadline, uptimeDeadline: uptimeDeadline, now: now, uptime: uptime)
        guard current > 0, current <= maximumDuration + 0.000001 else { return nil }
        let duration = target.seconds
        guard duration + 0.000001 >= current else { return nil }
        // The duration is a target from now. Compare it with the effective remaining
        // time above, then rebase both clocks so recovery preserves that target
        // even after sleep or a wall-clock adjustment.
        return Extension(wallDeadline: now + duration, uptimeDeadline: uptime + duration, remaining: duration)
    }
}

enum FocusShutdown {
    static func isSystemRequest(_ reason: UInt32?) -> Bool {
        guard let reason = reason else { return false }
        return [UInt32(kAEShutDown), UInt32(kAERestart), UInt32(kAEReallyLogOut)].contains(reason)
    }
}

/// macOS delivers sleep, display and user-session events independently. One
/// wake event must not release a suspension still owned by another source.
struct FocusSuspensions {
    enum Reason: Hashable { case systemSleep, displaySleep, inactiveSession, sessionEnding }
    private var reasons = Set<Reason>()
    var isSuspended: Bool { !reasons.isEmpty }
    mutating func suspend(_ reason: Reason) { reasons.insert(reason) }
    @discardableResult mutating func resume(_ reason: Reason) -> Bool {
        reasons.remove(reason)
        return reasons.isEmpty
    }
}

enum FocusRecovery {
    /// Wait without initializing a UI. Check again after taking ownership so
    /// deliberate unlock/expiry cannot race into an unwanted restart.
    static func waitForOwnership(isActive: () -> Bool, acquire: () -> Bool,
                                 wait: () -> Void = { Thread.sleep(forTimeInterval: 0.5) }) -> Bool {
        while isActive() {
            if acquire() { return isActive() }
            wait()
        }
        return false
    }
}

final class HarmonyInstanceLock {
    private var descriptor: Int32 = -1
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        if descriptor < 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    func acquire(timeout: TimeInterval = 0) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            if errno != EWOULDBLOCK && errno != EAGAIN { return false }
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            usleep(20_000)
        } while true
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor) } }
}

struct HarmonyCommandReply {
    let rejection: String?
    let message: String?
    init(rejection: String? = nil, message: String? = nil) {
        self.rejection = rejection; self.message = message
    }
}

/// Retain the original result and message so retries neither repeat a mutation
/// nor change an accepted request into a rejection after it changes state.
final class HarmonyCommandReceipts {
    struct Receipt {
        let isNew: Bool
        let reply: HarmonyCommandReply
        var rejection: String? { reply.rejection }
        var message: String? { reply.message }
    }
    private var outcomes: [String: HarmonyCommandReply] = [:]
    private var order: [String] = []
    func receive(_ id: String, decide: () -> HarmonyCommandReply) -> Receipt {
        if let stored = outcomes[id] { return Receipt(isNew: false, reply: stored) }
        let reply = decide()
        outcomes[id] = reply
        order.append(id)
        if order.count > 128 { outcomes.removeValue(forKey: order.removeFirst()) }
        return Receipt(isNew: true, reply: reply)
    }
}

enum HarmonyCommandChannel {
    static let commandName = Notification.Name("local.harmony.focus.command")
    static let acknowledgementName = Notification.Name("local.harmony.focus.command.ack")

    /// Returns when the running app accepts the request, not when a password dialog is completed.
    static func send(_ command: HarmonyCommand, timeout: TimeInterval = 5, namespace: String = "local.harmony.focus", onRejection: ((String) -> Void)? = nil, onMessage: ((String) -> Void)? = nil) -> Bool {
        let center = DistributedNotificationCenter.default()
        let requestID = UUID().uuidString
        let commandName = Notification.Name(namespace + ".command")
        let acknowledgementName = Notification.Name(namespace + ".command.ack")
        var acknowledged = false
        var rejection: String?
        var message: String?
        let token = center.addObserver(forName: acknowledgementName, object: requestID, queue: nil) { notification in
            rejection = notification.userInfo?["rejection"] as? String
            message = notification.userInfo?["message"] as? String
            acknowledged = true
        }
        defer { center.removeObserver(token) }
        var info: [String: Any] = ["action": command.action, "requestID": requestID]
        if let hours = command.hours { info["hours"] = hours }
        if command.minutes != 0 { info["minutes"] = command.minutes }
        let end = ProcessInfo.processInfo.systemUptime + timeout
        var nextPost: TimeInterval = 0
        while !acknowledged && ProcessInfo.processInfo.systemUptime < end {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextPost {
                center.postNotificationName(commandName, object: nil, userInfo: info, deliverImmediately: true)
                nextPost = now + 0.15
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
        if let rejection = rejection { onRejection?(rejection) }
        if acknowledged, rejection == nil, let message = message { onMessage?(message) }
        return acknowledged && rejection == nil
    }
    static func acknowledge(_ requestID: String, namespace: String = "local.harmony.focus", rejection: String? = nil, message: String? = nil) {
        var info: [String: String] = [:]
        if let rejection = rejection { info["rejection"] = rejection }
        if let message = message { info["message"] = message }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(namespace + ".command.ack"), object: requestID, userInfo: info.isEmpty ? nil : info, deliverImmediately: true)
    }
}
