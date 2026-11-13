import AppKit

/// Explicit benchmark fixture only. NSButton.performClick may animate before
/// delivering its action; timestamp delivery without bypassing production Send.
@MainActor final class PerformanceButtonAction: NSObject {
    private weak var button: NSButton?
    private let originalTarget: AnyObject?
    private let originalAction: Selector?
    private let clock: @MainActor () -> Double
    private(set) var deliveredAt: Double?
    private(set) var forwarded = false
    private(set) var forwardCount = 0

    init(button: NSButton, clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.button = button; originalTarget = button.target as AnyObject?; originalAction = button.action; self.clock = clock
        super.init()
        button.target = self; button.action = #selector(deliver(_:))
    }
    @objc private func deliver(_ sender: Any?) {
        guard deliveredAt == nil, let button, let originalAction else { return }
        forwardCount += 1
        deliveredAt = clock()
        forwarded = NSApp.sendAction(originalAction, to: originalTarget, from: button)
    }
    func restore() {
        guard let button, (button.target as AnyObject?) === self, button.action == #selector(deliver(_:)) else { return }
        button.target = originalTarget; button.action = originalAction
    }
}
