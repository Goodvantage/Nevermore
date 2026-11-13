import Foundation
import Testing
@testable import NevermoreCore

@MainActor struct UpdateMonitorTests {
    private let running = ReleaseVersion("1.2.2")!
    private let preferences = UpdateTestPreferences()
    private func defaults() -> UserDefaults { preferences.value }
    private func offer(_ version: String = "1.2.3") throws -> ReleaseOffer {
        try #require(try ReleaseOffer.decode(ReleaseCheckTests.manifest(version: version), running: running))
    }

    @Test func manualCheckWorksWhenAutomaticIsOff() async throws {
        let defaults = defaults(), offer = try offer()
        defaults.set(false, forKey: UpdateMonitor.automaticKey)
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults, fetch: { _ in offer })
        #expect(!monitor.checksAutomatically)
        await monitor.check(.automatic)
        #expect(monitor.result == .notChecked)
        await monitor.check(.manual)
        #expect(monitor.offer == offer && monitor.result == .checked)
        monitor.stop()
    }

    @Test func manualOnlyModeCannotStartBackgroundChecksFromPreferences() async throws {
        let source = ReleaseSource(offer: try offer()), clock = ReleaseClock()
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults(), scheduling: .manualOnly,
            fetch: { _ in try await source.fetch() }, sleep: { try await clock.sleep($0) })
        monitor.start()
        monitor.setChecksAutomatically(false); monitor.setChecksAutomatically(true)
        await monitor.check(.automatic)
        #expect(await source.calls == 0)
        #expect(await clock.durations.isEmpty)
        await monitor.check(.manual)
        #expect(await source.calls == 1 && monitor.offer != nil)
        monitor.stop()
    }

    @Test func dismissalAndAnnouncementSurviveRestart() async throws {
        let defaults = defaults(), offer = try offer()
        let first = UpdateMonitor(runningVersion: running, defaults: defaults, fetch: { _ in offer })
        var announcements = 0
        first.onAnnouncement = { _ in announcements += 1 }
        #expect(first.checksAutomatically)
        await first.check(.automatic); await first.check(.manual)
        #expect(announcements == 1 && first.visibleOffer == offer)
        first.dismiss(); first.stop()
        let next = UpdateMonitor(runningVersion: running, defaults: defaults, fetch: { _ in offer })
        next.onAnnouncement = { _ in announcements += 1 }
        await next.check(.automatic)
        #expect(announcements == 1 && next.visibleOffer == nil && next.offer == offer)
        await next.check(.manual)
        #expect(next.offer == offer) // Explicit checks can still review a dismissed offer.
        next.stop()
        let newer = try self.offer("1.2.4")
        let third = UpdateMonitor(runningVersion: running, defaults: defaults, fetch: { _ in newer })
        third.onAnnouncement = { _ in announcements += 1 }
        await third.check(.automatic)
        #expect(announcements == 2 && third.visibleOffer == newer)
        third.stop()
    }

    @Test func failureDoesNotClaimSuccessOrLoseKnownOffer() async throws {
        let source = ReleaseSource(offer: try offer())
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults(), fetch: { _ in try await source.fetch() })
        var announcements = 0
        monitor.onAnnouncement = { _ in announcements += 1 }
        await monitor.check(.manual)
        let previous = monitor.offer
        await source.fail()
        await monitor.check(.manual)
        #expect(monitor.offer == previous && announcements == 1 && !monitor.isChecking)
        guard case .failed = monitor.result else { Issue.record("Failed check reported success"); return }
        await source.withdraw()
        await monitor.check(.manual)
        #expect(monitor.result == .checked && monitor.offer == nil)
        monitor.stop()
    }

    @Test func concurrentChecksCoalesceAndOptOutRejectsLateAutomaticResult() async throws {
        let gate = ReleaseGate(), offer = try offer()
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults(), fetch: { _ in await gate.fetch() })
        let first = Task { await monitor.check(.automatic) }
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.started)
        let joined = Task { await monitor.check(.automatic) }
        await Task.yield()
        #expect(await gate.count == 1)
        monitor.setChecksAutomatically(false)
        await gate.resolve(offer)
        await first.value; await joined.value
        #expect(monitor.offer == nil && monitor.result == .notChecked && !monitor.isChecking)
        monitor.stop()
    }

    @Test func optingOutDoesNotLoseAnExplicitCheckJoiningAnAutomaticRequest() async throws {
        let gate = ReleaseGate(), offer = try offer()
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults(), fetch: { _ in await gate.fetch() })
        let automatic = Task { await monitor.check(.automatic) }
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.started)
        monitor.setChecksAutomatically(false)
        var joined = false
        let manual = Task { joined = true; await monitor.check(.manual) }
        for _ in 0..<200 { if joined { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(joined)
        await gate.resolve(offer)
        await automatic.value; await manual.value
        #expect(await gate.count == 1)
        #expect(monitor.offer == offer && monitor.result == .checked)
        monitor.stop()
    }

    @Test func stoppedMonitorRejectsLateResults() async throws {
        let gate = ReleaseGate(), offer = try offer()
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults(), fetch: { _ in await gate.fetch() })
        let task = Task { await monitor.check(.manual) }
        for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.started)
        monitor.stop()
        await gate.resolve(offer)
        await task.value
        #expect(monitor.offer == nil && monitor.result == .notChecked)
    }

    @Test func scheduleChecksAfterLaunchThenDaily() async throws {
        let clock = ReleaseClock(), source = ReleaseSource(offer: nil)
        let monitor = UpdateMonitor(runningVersion: running, defaults: defaults(),
            fetch: { _ in try await source.fetch() }, sleep: { try await clock.sleep($0) })
        monitor.start(); monitor.start()
        for _ in 0..<200 { if await clock.durations.count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await clock.durations == [.seconds(10), .seconds(86_400)])
        #expect(await source.calls == 1)
        monitor.stop()
    }
}

private final class UpdateTestPreferences {
    private let name = "NevermoreUpdates-\(UUID())"
    let value: UserDefaults
    init() { value = UserDefaults(suiteName: name)! }
    deinit { value.removePersistentDomain(forName: name) }
}

private actor ReleaseSource {
    private var offer: ReleaseOffer?
    private var failed = false
    private(set) var calls = 0
    init(offer: ReleaseOffer?) { self.offer = offer }
    func fail() { failed = true }
    func withdraw() { failed = false; offer = nil }
    func fetch() throws -> ReleaseOffer? {
        calls += 1
        if failed { throw ReleaseCheckError.unavailable }
        return offer
    }
}
private actor ReleaseGate {
    private var continuation: CheckedContinuation<ReleaseOffer?, Never>?
    private var resolved = false
    private var resolution: ReleaseOffer?
    private(set) var count = 0
    var started: Bool { continuation != nil }
    func fetch() async -> ReleaseOffer? {
        count += 1
        if resolved { return resolution }
        return await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ offer: ReleaseOffer?) {
        resolved = true; resolution = offer
        continuation?.resume(returning: offer); continuation = nil
    }
}
private actor ReleaseClock {
    private(set) var durations: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        if durations.count == 1 { return }
        try await Task.sleep(for: .seconds(60))
    }
}
