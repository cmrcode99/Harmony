import Cocoa

private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var ranOnMain = false
    private var cancelled = false
    func start() -> Int { lock.lock(); defer { lock.unlock() }; calls += 1; ranOnMain = ranOnMain || Thread.isMainThread; return calls }
    func recordCancellation(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }
    func snapshot() -> (Int, Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (calls, ranOnMain, cancelled) }
}

@main struct WindowPreparationTests {
    @MainActor static func waitFor(_ label: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        fatalError("Timed out waiting for window worker: \(label)")
    }
    @MainActor static func main() async {
        _ = NSApplication.shared // Register this windowless test process with AppKit.
        let app = NSRunningApplication.current
        let state = ProbeState()
        let gate = DispatchSemaphore(value: 0)
        var publications: [[String: String]] = []
        let controller = WindowPreparation(retryInterval: 0.01, timeout: 2, probe: { _, valid in
            let call = state.start()
            if call == 1 {
                _ = gate.wait(timeout: .now() + 1)
                state.recordCancellation(!valid())
                return .init(complete: true, eligibleWindows: 1, message: "stale")
            }
            return .init(complete: true, eligibleWindows: 1, message: "current")
        }, publish: { publications.append($0) })
        let generation = controller.begin()
        let start = ProcessInfo.processInfo.systemUptime
        controller.enqueue(app, generation: generation)
        precondition(ProcessInfo.processInfo.systemUptime - start < 0.1, "enqueue blocked on AX worker")
        await waitFor("first probe") { state.snapshot().0 == 1 }
        controller.userActivated(app)
        let nextGeneration = controller.begin()
        controller.enqueue(app, generation: nextGeneration)
        gate.signal()
        await waitFor("current generation result") { publications.last?.values.contains("current") == true }
        precondition(!state.snapshot().1, "AX work ran on main thread")
        precondition(state.snapshot().2, "user activation did not revoke in-flight worker")
        precondition(!publications.contains(where: { $0.values.contains("stale") }), "stale callback changed current generation")

        let cancelledState = ProbeState()
        let cancelGate = DispatchSemaphore(value: 0)
        var cancelledPublications: [[String: String]] = []
        let cancelledController = WindowPreparation(retryInterval: 0.01, timeout: 2, probe: { _, valid in
            _ = cancelledState.start()
            _ = cancelGate.wait(timeout: .now() + 1)
            cancelledState.recordCancellation(!valid())
            return .init(complete: true, eligibleWindows: 1, message: "cancelled result")
        }, publish: { cancelledPublications.append($0) })
        let cancelledGeneration = cancelledController.begin()
        cancelledController.enqueue(app, generation: cancelledGeneration)
        await waitFor("cancel probe") { cancelledState.snapshot().0 == 1 }
        cancelledController.cancel()
        cancelGate.signal()
        await waitFor("cancellation observation") { cancelledState.snapshot().2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        precondition(cancelledState.snapshot().0 == 1, "cancelled work retried")
        precondition(cancelledPublications.count == 1, "cancelled work published late results")

        let releasedState = ProbeState()
        let releaseGate = DispatchSemaphore(value: 0)
        var releasedController: WindowPreparation? = WindowPreparation(retryInterval: 0.01, timeout: 2, probe: { _, valid in
            _ = releasedState.start()
            _ = releaseGate.wait(timeout: .now() + 1)
            releasedState.recordCancellation(!valid())
            return .init(complete: true, eligibleWindows: 1, message: "released result")
        }, publish: { _ in })
        let releasedGeneration = releasedController!.begin()
        releasedController!.enqueue(app, generation: releasedGeneration)
        await waitFor("released-owner probe") { releasedState.snapshot().0 == 1 }
        releasedController = nil
        releaseGate.signal()
        await waitFor("released-owner cancellation") { releasedState.snapshot().2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        precondition(releasedState.snapshot().0 == 1, "Work retried after its coordinator was released")
        print("PASS window preparation: nonblocking enqueue, off-main work, activation cancellation, stale-generation rejection, no retries after cancel")
        print("PASS window preparation lifetime: releasing the owner revokes in-flight work without retaining the coordinator")
    }
}
