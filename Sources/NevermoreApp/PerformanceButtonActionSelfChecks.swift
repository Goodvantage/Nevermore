import AppKit
import NevermoreCore

/// Hidden native target/action calibration with a deterministic monotonic clock.
/// It models a pre-action flash delay; no window, send or performClick occurs.
@MainActor enum PerformanceButtonActionSelfChecks {
    @MainActor private final class Probe: NSObject {
        var calls = 0
        weak var sender: NSButton?
        @objc func receive(_ sender: NSButton) { calls += 1; self.sender = sender }
    }
    @MainActor private final class Clock {
        var value = 10.0
    }
    private enum CalibrationError: Error { case expected }
    static func run() -> [(String, Bool)] {
        let probe = Probe(), button = NSButton()
        let selector = #selector(Probe.receive(_:))
        button.target = probe; button.action = selector
        let clock = Clock()
        var checks: [(String, Bool)] = []
        do {
            let action = PerformanceButtonAction(button: button, clock: { clock.value })
            defer { action.restore() }
            let began = clock.value
            // Simulate the 100 ms before NSButton delivers its callback.
            clock.value = 10.1
            let delivered = NSApp.sendAction(button.action!, to: button.target, from: button)
            let sample = action.deliveredAt.flatMap { PerformanceMetrics.feedbackSample(clickStarted: began, actionDelivered: $0, observed: 10.125) }
            checks.append(("Send benchmark separates pre-action delay from delivered-action feedback", delivered && action.forwarded && sample.map { abs($0.clickToFeedbackMS - 125) < 0.000001 && abs($0.actionToFeedbackMS - 25) < 0.000001 && abs($0.preActionMS - 100) < 0.000001 } == true))
            _ = NSApp.sendAction(button.action!, to: button.target, from: button)
            checks.append(("Send benchmark forwards the original action and sender exactly once", action.forwardCount == 1 && probe.calls == 1 && probe.sender === button))
        }
        checks.append(("Send benchmark restores the original target and selector after measurement", (button.target as AnyObject?) === probe && button.action == selector))
        do {
            let action = PerformanceButtonAction(button: button)
            defer { action.restore() }
            throw CalibrationError.expected
        } catch {
            // Expected failure verifies defer restores the original action.
        }
        checks.append(("Send benchmark restores the original target and selector on failure", (button.target as AnyObject?) === probe && button.action == selector))
        return checks
    }
}
