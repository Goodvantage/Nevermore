import AppKit
import RavenProtocol

/// Exercises scheduling without network access; the worker is stopped before
/// its debounce can issue a request.
@MainActor enum ReconciliationSelfChecks {
    static func run() async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreReconcile-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(origin: URL(string: "https://reconciliation.invalid")!, user: "fixture", siteName: "fixture", clientID: "fixture")
        let session = try AccountSession(account: account, directory: directory)
        defer { session.stop() }
        let firstWindow = UUID(), secondWindow = UUID()
        session.attach(window: firstWindow, channelID: "channel")
        session.attach(window: secondWindow, channelID: "channel")
        var results: [(String, Bool)] = []
        session.realtimeLive = true
        session.reconciliationTick(now: Date().addingTimeInterval(120), isActive: false)
        results.append(("live background sessions skip periodic refresh", session.reconciliationTask == nil))
        session.realtimeLive = false
        session.reconciliationTick(now: Date(), isActive: false)
        let worker = session.reconciliationTask
        results.append(("offline background sessions schedule catch-up for open windows", worker != nil && Set(session.interests.values) == ["channel"]))
        try await Task.sleep(for: .milliseconds(20))
        session.requestReconciliation(); session.requestReconciliation()
        results.append(("concurrent catch-up requests share a worker and request another pass", session.reconciliationTask != nil && session.reconcileRequested))
        session.stop()
        await worker?.value
        session.requestReconciliation()
        results.append(("stopping cancels reconciliation and prevents later requests", session.reconciliationTask == nil && session.stopped))
        let activationAccount = Account(origin: account.origin, user: "activation-fixture", siteName: "fixture", clientID: "fixture")
        let activation = try AccountSession(account: activationAccount, directory: directory.appendingPathComponent("activation"))
        defer { activation.stop() }
        activation.attach(window: UUID(), channelID: "channel")
        let app = AppDelegate(); app.sessions = [activation]
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        results.append(("app activation requests catch-up for interested accounts", activation.reconciliationTask != nil))
        let activationWorker = activation.reconciliationTask
        activation.stop(); await activationWorker?.value
        return results
    }
}
