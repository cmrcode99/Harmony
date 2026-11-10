import Cocoa
import ApplicationServices

/// Coordinates a bounded pass over each approved app. AX calls run on one
/// utility queue; main-thread state only schedules work and publishes results.
@MainActor final class WindowPreparation {
    struct ProbeResult: Sendable {
        let complete: Bool
        let eligibleWindows: Int
        let message: String?
        static func retry(_ message: String) -> Self { .init(complete: false, eligibleWindows: 0, message: message) }
    }
    typealias Probe = @Sendable (pid_t, @escaping @Sendable () -> Bool) -> ProbeResult

    /// A worker checks this before every AX operation, especially mutations.
    /// Revocation never waits for an unresponsive application's AX reply.
    private final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        func revoke() { lock.lock(); active = false; lock.unlock() }
        func isActive() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    }
    private final class Job: @unchecked Sendable {
        let pid: pid_t
        let id: String
        let generation: Int
        let deadline: TimeInterval
        let permit = Permit()
        var quietPasses = 0 // Accessed only by the main actor.
        init(pid: pid_t, id: String, generation: Int, deadline: TimeInterval) {
            self.pid = pid; self.id = id; self.generation = generation; self.deadline = deadline
        }
        func shouldProceed() -> Bool {
            permit.isActive() && ProcessInfo.processInfo.systemUptime < deadline
        }
    }

    private let queue = DispatchQueue(label: "local.harmony.window-preparation", qos: .utility)
    private let probe: Probe
    private let publish: ([String: String]) -> Void
    private let retryInterval: TimeInterval
    private let timeout: TimeInterval
    private var pending: [pid_t: Job] = [:]
    private var results: [String: String] = [:]
    private(set) var generation = 0
    private var acceptsPendingApps = false
    private var userActivatedIDs = Set<String>()
    var isEnabled: () -> Bool = { true }

    init(retryInterval: TimeInterval = 0.25, timeout: TimeInterval = 5,
         probe: Probe? = nil,
         publish: @escaping ([String: String]) -> Void = { UserDefaults.standard.set($0, forKey: "lastAppPreparation") }) {
        self.retryInterval = retryInterval
        self.timeout = timeout
        self.probe = probe ?? { @Sendable pid, shouldProceed in Self.probeWindows(pid, shouldProceed: shouldProceed) }
        self.publish = publish
    }

    func begin() -> Int {
        cancel()
        acceptsPendingApps = true
        userActivatedIDs.removeAll()
        results.removeAll()
        publish(results)
        return generation
    }

    func enqueue(_ app: NSRunningApplication, generation expected: Int) {
        let id = app.bundleIdentifier ?? String(app.processIdentifier)
        guard isEnabled(), acceptsPendingApps, expected == generation, !app.isTerminated,
              id != "com.cmuxterm.app", !userActivatedIDs.contains(id),
              pending[app.processIdentifier] == nil else { return }
        let job = Job(pid: app.processIdentifier, id: id, generation: generation,
                      deadline: ProcessInfo.processInfo.systemUptime + timeout)
        pending[job.pid] = job
        schedule(job)
    }

    func userActivated(_ app: NSRunningApplication) {
        let id = app.bundleIdentifier ?? String(app.processIdentifier)
        userActivatedIDs.insert(id)
        if let job = pending.removeValue(forKey: app.processIdentifier) {
            job.permit.revoke()
            setResult("Left open after activation", for: id)
        }
    }

    func cancel() {
        acceptsPendingApps = false
        for job in pending.values { job.permit.revoke() }
        pending.removeAll()
        generation += 1
    }

    private func setResult(_ value: String, for id: String) {
        guard results[id] != value else { return }
        results[id] = value
        publish(results)
    }

    private func schedule(_ job: Job, delay: TimeInterval = 0) {
        let probe = self.probe
        queue.asyncAfter(deadline: .now() + delay) { [weak self, job] in
            guard job.shouldProceed() else {
                Task { @MainActor [weak self] in self?.receive(.retry("Window preparation timed out"), for: job) }
                return
            }
            // Yield fairly between apps even if one has many slow AX windows.
            let passDeadline = ProcessInfo.processInfo.systemUptime + 0.4
            let result = probe(job.pid, { job.shouldProceed() && ProcessInfo.processInfo.systemUptime < passDeadline })
            Task { @MainActor [weak self] in self?.receive(result, for: job) }
        }
    }

    private func receive(_ result: ProbeResult, for job: Job) {
        guard pending[job.pid] === job, job.generation == generation, job.permit.isActive() else { return }
        guard isEnabled() else { cancel(); return }
        job.quietPasses = result.complete ? job.quietPasses + 1 : 0
        if job.quietPasses >= 3 || (result.complete && result.message != nil) {
            pending.removeValue(forKey: job.pid)
            job.permit.revoke()
            setResult(result.message ?? (result.eligibleWindows > 0 ? "Minimized (verified)" : "Running without a minimizable window"), for: job.id)
        } else if ProcessInfo.processInfo.systemUptime >= job.deadline {
            pending.removeValue(forKey: job.pid)
            job.permit.revoke()
            setResult(result.message ?? "Window could not be minimized; left unchanged", for: job.id)
        } else {
            schedule(job, delay: retryInterval)
        }
    }

    nonisolated private static func probeWindows(_ pid: pid_t, shouldProceed: @escaping @Sendable () -> Bool) -> ProbeResult {
        guard shouldProceed() else { return .retry("Window preparation cancelled") }
        guard AXIsProcessTrusted() else {
            return .init(complete: true, eligibleWindows: 0, message: "Control permission required; window left unchanged")
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var raw: CFTypeRef?
        guard shouldProceed() else { return .retry("Window preparation cancelled") }
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard error == .success, let windows = raw as? [AXUIElement] else {
            return .retry("Window query failed: \(error.rawValue)")
        }
        guard !windows.isEmpty else { return .retry("Running without a window") }
        var allDone = true
        var eligibleWindows = 0
        for window in windows {
            guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
            AXUIElementSetMessagingTimeout(window, 0.15)
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true { eligibleWindows += 1; continue }
            guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
            var settable = DarwinBoolean(false)
            let canSet = AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable)
            if canSet == .success && settable.boolValue {
                eligibleWindows += 1
                guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
                if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) != .success {
                    allDone = false; continue
                }
            } else {
                guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
                var rawButton: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizeButtonAttribute as CFString, &rawButton) == .success,
                   let rawButton = rawButton, CFGetTypeID(rawButton) == AXUIElementGetTypeID() {
                    let button = unsafeBitCast(rawButton, to: AXUIElement.self)
                    AXUIElementSetMessagingTimeout(button, 0.15)
                    eligibleWindows += 1
                    guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
                    if AXUIElementPerformAction(button, kAXPressAction as CFString) != .success {
                        allDone = false; continue
                    }
                } else {
                    var subrole: CFTypeRef?
                    guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
                    _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                    if (subrole as? String) == (kAXStandardWindowSubrole as String) { allDone = false }
                    continue
                }
            }
            guard shouldProceed() else { return .retry("Window preparation cancelled or timed out") }
            var verified: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &verified) != .success ||
               (verified as? Bool) != true { allDone = false }
        }
        return .init(complete: allDone, eligibleWindows: eligibleWindows, message: nil)
    }
}
