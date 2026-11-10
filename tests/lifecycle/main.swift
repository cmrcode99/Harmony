import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--send" {
    exit(HarmonyCommandChannel.send(HarmonyCommand(action: "show", hours: nil), timeout: 1.5, namespace: CommandLine.arguments[2]) ? 0 : 1)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--send-reject" {
    var reason: String?
    let accepted = HarmonyCommandChannel.send(HarmonyCommand(action: "lock", hours: 1), timeout: 1.5,
        namespace: CommandLine.arguments[2], onRejection: { reason = $0 })
    exit(!accepted && reason == "test rejection" ? 0 : 1)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--send-message" {
    var message: String?
    let accepted = HarmonyCommandChannel.send(HarmonyCommand(action: "extend", hours: 4, minutes: 30), timeout: 1.5,
        namespace: CommandLine.arguments[2], onMessage: { message = $0 })
    exit(accepted && message == "extended result" ? 0 : 1)
}
let lockCommand = HarmonyCommand(action: "lock", hours: 1)
for locked in [false, true] {
    for hours in 1...5 {
        check(HarmonyCommand(action: "lock", hours: hours).rejection(isLocked: locked, promptBusy: false, focusEnabled: true) == "Another instance of Harmony is already running.", "running start modified session")
    }
    check(HarmonyCommand(action: "show", hours: nil).rejection(isLocked: locked, promptBusy: false, focusEnabled: true) != nil, "running base command accepted")
}
check(lockCommand.rejection(isLocked: true, promptBusy: false, focusEnabled: true) != nil, "active lock not rejected")
check(lockCommand.rejection(isLocked: false, promptBusy: true, focusEnabled: true) != nil, "busy prompt not rejected")
check(lockCommand.rejection(isLocked: false, promptBusy: false, focusEnabled: false) != nil, "running instance accepted a new lock")
check(HarmonyCommand(action: "phone", hours: nil).rejection(isLocked: false, promptBusy: false, focusEnabled: false) != nil, "inactive phone not rejected")
let exitCommand = HarmonyCommand(action: "exit", hours: nil)
check(exitCommand.rejection(isLocked: true, promptBusy: false, focusEnabled: true) != nil, "timed CLI exit was allowed")
check(exitCommand.rejection(isLocked: false, promptBusy: false, focusEnabled: true) == nil, "base CLI exit was blocked")
let receipts = HarmonyCommandReceipts()
var decisions = 0
let acceptedReceipt = receipts.receive("first") { decisions += 1; return HarmonyCommandReply(message: "original result") }
let acceptedRetry = receipts.receive("first") { decisions += 1; return HarmonyCommandReply(rejection: "state changed") }
check(acceptedReceipt.isNew && acceptedReceipt.rejection == nil && !acceptedRetry.isNew && acceptedRetry.rejection == nil && decisions == 1, "accepted retry recomputed outcome")
check(acceptedReceipt.message == "original result" && acceptedRetry.message == "original result", "retry lost original result message")
let rejectedReceipt = receipts.receive("second") { HarmonyCommandReply(rejection: "busy") }
let rejectedRetry = receipts.receive("second") { HarmonyCommandReply() }
check(rejectedReceipt.isNew && rejectedReceipt.rejection == "busy" && !rejectedRetry.isNew && rejectedRetry.rejection == "busy", "rejected retry recomputed outcome")
for hour in 1...5 {
    check(HarmonyCommand.parse(action: "lock", hours: String(hour)) == HarmonyCommand(action: "lock", hours: hour), "valid hours")
    check(HarmonyCommand.parse(action: "extend", hours: String(hour)) == HarmonyCommand(action: "extend", hours: hour), "valid extension hours")
    let extend = HarmonyCommand(action: "extend", hours: hour)
    check(extend.rejection(isLocked: true, promptBusy: false, focusEnabled: true) == nil, "active timed extension rejected")
    check(extend.rejection(isLocked: false, promptBusy: false, focusEnabled: true) != nil, "untimed extension accepted")
    check(extend.rejection(isLocked: false, promptBusy: false, focusEnabled: false) != nil, "expired extension accepted")
    check(extend.rejection(isLocked: true, promptBusy: false, focusEnabled: false) != nil, "disabled session extended")
    check(extend.rejection(isLocked: true, promptBusy: true, focusEnabled: true) != nil, "busy prompt extension accepted")
}
for invalid in ["0", "6", "-1", "1.0", "01", "+1", "NaN", "", " 1"] {
    check(HarmonyCommand.parse(action: "lock", hours: invalid) == nil, "invalid hour accepted: \(invalid)")
    check(HarmonyCommand.parse(action: "extend", hours: invalid) == nil, "invalid extension accepted: \(invalid)")
}
check(HarmonyCommand.parse(action: "extend") == nil, "missing extension hours accepted")
for hours in 0...5 {
    for minutes in 0...59 {
        let valid = hours * 60 + minutes > 0 && hours * 60 + minutes <= 300
        for action in ["lock", "extend"] {
            let command = HarmonyCommand.parse(arguments: [action, String(hours), String(format: "%02d", minutes)])
            check((command != nil) == valid, "duration boundary disagrees with parser")
            if let command = command {
                check(command.hours == hours && command.minutes == minutes, "minute payload lost or changed")
                check(HarmonyDuration(hours: hours, minutes: minutes)?.seconds == Double(hours * 3600 + minutes * 60), "duration units are incorrect")
            }
        }
    }
}
for args in [["lock","2","60"],["lock","5","1"],["extend","0","0"],["extend","4","059"],
             ["lock","01","30"],["lock","1","-1"],["hide","1","2"],["lock","1","2","3"]] {
    check(HarmonyCommand.parse(arguments: args) == nil, "malformed duration arguments accepted")
}
check(HarmonyCommand.parse(action: "hide", minutes: "0") == nil, "control command accepted a minute payload")
check(HarmonyDuration(hours: Int.max, minutes: Int.max) == nil, "overflow-sized duration accepted")
check(HarmonyCommand.parse(action: "show", hours: "1") == nil, "extraneous hours accepted")
check(HarmonyCommand.parse(action: "bogus") == nil, "unknown command accepted")
for action in ["show", "hide", "unhide", "phone", "exit"] {
    check(HarmonyCommand.parse(action: action) != nil, "valid action rejected")
}
check(FocusDeadline.restored(.nan, now: 100) == nil, "NaN deadline")
check(FocusDeadline.restored(.infinity, now: 100) == nil, "infinite deadline")
check(FocusDeadline.restored(99, now: 100) == nil, "expired deadline")
check(FocusDeadline.restored(1_000_000, now: 100) == 18_100, "restore duration cap")
check(FocusDeadline.remaining(wallDeadline: 1_100, uptimeDeadline: 1_010, now: 600, uptime: 11) == 500, "sleep must count toward a session")
check(FocusDeadline.remaining(wallDeadline: 1_100, uptimeDeadline: 1_010, now: 50, uptime: 510) == 500, "clock rollback must not lengthen a session")
check(FocusDeadline.remaining(wallDeadline: 1_100, uptimeDeadline: 1_010, now: 1_101, uptime: 12) == 0, "expired wall deadline")
let extended = FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 7_205, hours: 4, now: 100, uptime: 5)!
check(extended.remaining == 14_400 && extended.wallDeadline == 14_500 && extended.uptimeDeadline == 14_405, "two-hour session did not become four hours remaining")
check(FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 7_205, hours: 1, now: 100, uptime: 5) == nil, "extension shortened an active timer")
let maximum = FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 7_205, hours: 5, now: 100, uptime: 5)!
check(maximum.remaining == 18_000 && maximum.wallDeadline == 18_100 && maximum.uptimeDeadline == 18_005, "extension exceeded five hours remaining")
check(FocusDeadline.restored(maximum.wallDeadline, now: 700) == 18_100, "recovery discarded the extended deadline")
check(FocusDeadline.remaining(wallDeadline: maximum.wallDeadline, uptimeDeadline: nil, now: 700, uptime: 0) == 17_400, "recovered extension did not count elapsed time")
let rollbackExtension = FocusDeadline.extending(wallDeadline: 1_100, uptimeDeadline: 1_010, hours: 1, now: 50, uptime: 510)!
check(rollbackExtension.remaining == 3_600 && rollbackExtension.wallDeadline == 3_650 && rollbackExtension.uptimeDeadline == 4_110, "extension did not use the effective clock-safe target")
let sleepExtension = FocusDeadline.extending(wallDeadline: 1_100, uptimeDeadline: 1_010, hours: 1, now: 600, uptime: 11)!
check(sleepExtension.remaining == 3_600, "extension added hours instead of setting the requested post-sleep target")
for hours in [-1, 0, 6, Int.max] {
    check(FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 7_205, hours: hours, now: 100, uptime: 5) == nil, "out-of-range extension duration accepted")
}
check(FocusDeadline.extending(wallDeadline: 0, uptimeDeadline: nil, hours: 1, now: 100, uptime: 5) == nil, "extension started an untimed session")
check(FocusDeadline.extending(wallDeadline: 100, uptimeDeadline: 7_205, hours: 1, now: 100, uptime: 5) == nil, "extension revived an expired wall deadline")
check(FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 5, hours: 1, now: 100, uptime: 5) == nil, "extension revived an expired uptime deadline")
check(FocusDeadline.extending(wallDeadline: .nan, uptimeDeadline: 7_205, hours: 1, now: 100, uptime: 5) == nil, "invalid wall deadline extended")
check(FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: .infinity, hours: 1, now: 100, uptime: 5) == nil, "invalid uptime deadline extended")
check(FocusDeadline.extending(wallDeadline: 100_000, uptimeDeadline: nil, hours: 1, now: 100, uptime: 5) == nil, "corrupt over-cap timer was silently shortened")
print("Timer extension passed: active-only, five-hour cap, persisted recovery, sleep/clock protection and invalid state")
let minuteTarget = FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 7_205, hours: 4, minutes: 30, now: 100, uptime: 5)!
check(minuteTarget.remaining == 16_200 && minuteTarget.wallDeadline == 16_300 && minuteTarget.uptimeDeadline == 16_205, "4 30 did not produce four hours thirty minutes")
check(FocusDeadline.extending(wallDeadline: 16_300, uptimeDeadline: 16_205, hours: 4, minutes: 29, now: 100, uptime: 5) == nil, "minute target shortened a timer")
check(FocusDeadline.extending(wallDeadline: 1_300, uptimeDeadline: 1_205, hours: 0, minutes: 30, now: 100, uptime: 5)?.remaining == 1_800, "minute-only extension failed")
check(FocusDeadline.extending(wallDeadline: 7_300, uptimeDeadline: 7_205, hours: 5, minutes: 1, now: 100, uptime: 5) == nil, "five-hour maximum ignored minutes")
print("Hours/minutes passed: all boundaries, padded minutes, minute-only durations, target clock math and no shortening")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harmony-lock-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
var first: HarmonyInstanceLock? = try HarmonyInstanceLock(directory: directory)
let second = try HarmonyInstanceLock(directory: directory)
check(first!.acquire(), "first instance cannot acquire")
check(!second.acquire(), "duplicate instance acquired")
first = nil
check(second.acquire(), "released instance lock not reusable")
print("Lifecycle core passed: strict command validation, sleep/clock-safe deadlines, singleton lock.")

let namespace = "local.harmony.lifecycle-test." + UUID().uuidString
var receives = 0
let center = DistributedNotificationCenter.default()
let observer = center.addObserver(forName: Notification.Name(namespace + ".command"), object: nil, queue: nil) { notification in
    guard let id = notification.userInfo?["requestID"] as? String else { return }
    receives += 1
    HarmonyCommandChannel.acknowledge(id, namespace: namespace)
}
let sender = Process()
sender.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
sender.arguments = ["--send", namespace]
try sender.run()
let end = Date().addingTimeInterval(3)
while sender.isRunning && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
if sender.isRunning { sender.terminate(); fatalError("ACK sender timed out") }
check(sender.terminationStatus == 0 && receives >= 1, "command acknowledgement failed")
center.removeObserver(observer)
check(!HarmonyCommandChannel.send(HarmonyCommand(action: "show", hours: nil), timeout: 0.1, namespace: namespace + ".absent"), "missing server falsely acknowledged")
print("Command channel passed: cross-process ACK and missing-server timeout.")

let rejectionNamespace = namespace + ".rejected"
let rejectionObserver = center.addObserver(forName: Notification.Name(rejectionNamespace + ".command"), object: nil, queue: nil) { notification in
    guard let id = notification.userInfo?["requestID"] as? String else { return }
    HarmonyCommandChannel.acknowledge(id, namespace: rejectionNamespace, rejection: "test rejection")
}
let rejectedSender = Process()
rejectedSender.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
rejectedSender.arguments = ["--send-reject", rejectionNamespace]
try rejectedSender.run()
let rejectionEnd = Date().addingTimeInterval(3)
while rejectedSender.isRunning && Date() < rejectionEnd { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
if rejectedSender.isRunning { rejectedSender.terminate(); fatalError("rejected ACK sender timed out") }
check(rejectedSender.terminationStatus == 0, "command rejection reason was not delivered")
center.removeObserver(rejectionObserver)
print("Command state rejection and retry-stable receipts passed.")

let messageNamespace = namespace + ".message"
let messageObserver = center.addObserver(forName: Notification.Name(messageNamespace + ".command"), object: nil, queue: nil) { notification in
    guard let id = notification.userInfo?["requestID"] as? String,
          notification.userInfo?["action"] as? String == "extend",
          (notification.userInfo?["hours"] as? NSNumber)?.intValue == 4,
          (notification.userInfo?["minutes"] as? NSNumber)?.intValue == 30 else { return }
    HarmonyCommandChannel.acknowledge(id, namespace: messageNamespace, message: "extended result")
}
let messageSender = Process()
messageSender.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
messageSender.arguments = ["--send-message", messageNamespace]
try messageSender.run()
let messageEnd = Date().addingTimeInterval(3)
while messageSender.isRunning && Date() < messageEnd { RunLoop.current.run(until: Date().addingTimeInterval(0.025)) }
if messageSender.isRunning { messageSender.terminate(); fatalError("message ACK sender timed out") }
check(messageSender.terminationStatus == 0, "extension result message was not delivered")
center.removeObserver(messageObserver)
print("Extension transport passed: hours payload and result message delivered across processes")

var waits = 0
var acquisitions = 0
let expiredWhileOwned = FocusRecovery.waitForOwnership(isActive: { waits == 0 }, acquire: { acquisitions += 1; return false }, wait: { waits += 1 })
check(!expiredWhileOwned && acquisitions == 1 && waits == 1, "intentional expiry restarted UI")
var activeReads = 0
let expiredOnRelease = FocusRecovery.waitForOwnership(isActive: { activeReads += 1; return activeReads == 1 }, acquire: { true }, wait: { fatalError("unexpected wait") })
check(!expiredOnRelease, "unlock racing ownership restarted UI")
check(FocusRecovery.waitForOwnership(isActive: { true }, acquire: { true }, wait: { fatalError("unexpected wait") }), "active lock was not recovered")
print("Passive recovery passed: wait, expiry, unlock race, crash ownership")

check(FocusShutdown.isSystemRequest(0x73687574), "system shutdown blocked")
check(FocusShutdown.isSystemRequest(0x72657374), "system restart blocked")
check(FocusShutdown.isSystemRequest(0x726c676f), "system logout blocked")
check(!FocusShutdown.isSystemRequest(nil) && !FocusShutdown.isSystemRequest(0x71756961), "ordinary quit bypassed lock")
print("System quit classification passed")

var suspensions = FocusSuspensions()
suspensions.suspend(.inactiveSession)
suspensions.suspend(.displaySleep)
suspensions.suspend(.systemSleep)
check(!suspensions.resume(.systemSleep) && suspensions.isSuspended, "system wake released a sleeping display/inactive session")
check(!suspensions.resume(.displaySleep) && suspensions.isSuspended, "display wake released an inactive session")
check(!suspensions.resume(.displaySleep), "duplicate wake released another suspension")
check(suspensions.resume(.inactiveSession) && !suspensions.isSuspended, "fully active session did not resume")
suspensions.suspend(.systemSleep)
check(!suspensions.resume(.inactiveSession), "early session-active event released system sleep")
check(suspensions.resume(.systemSleep), "system wake did not resume")
suspensions.suspend(.sessionEnding)
check(!suspensions.resume(.displaySleep) && !suspensions.resume(.inactiveSession), "wake resurrected interactions during logout")
print("Independent sleep/display/session suspension passed")
