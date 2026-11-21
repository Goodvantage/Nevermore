import AppKit
import NevermoreCore

@MainActor enum HomeOrderSelfChecks {
    static func run() -> [(String, Bool)] {
        let original = UserDefaults.standard.object(forKey: HomeLayout.defaultsKey)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: HomeLayout.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: HomeLayout.defaultsKey) }
            NotificationCenter.default.post(name: .homeLayoutChanged, object: nil)
        }
        var initial = HomeLayout.standard
        let hiddenModule = initial.order[1]
        initial.setVisible(hiddenModule, false)
        HomePreferences.layout = initial
        let controller = HomeCustomizeController()
        let panel = controller.view
        let buttons = InteractionSelfChecks.descendants(panel, of: NSButton.self)
        guard let table = InteractionSelfChecks.descendants(panel, of: NSTableView.self).first,
              let up = buttons.first(where: { $0.accessibilityLabel() == "Move Up" }),
              let down = buttons.first(where: { $0.accessibilityLabel() == "Move Down" }) else {
            return [("Customize Home offers accessible reorder buttons", false)]
        }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        _ = up.accessibilityPerformPress()
        let moved = HomePreferences.layout
        let atTop = moved.order.first == hiddenModule && moved.hidden.contains(hiddenModule)
            && table.selectedRow == 0 && !up.isEnabled && down.isEnabled
        _ = down.accessibilityPerformPress()
        let back = HomePreferences.layout.order == initial.order && table.selectedRow == 1 && up.isEnabled
        table.selectRowIndexes(IndexSet(integer: initial.order.count - 1), byExtendingSelection: false)
        return [
            ("a hidden Home module moves up and stays selected at the first position", atTop),
            ("Move Down restores the module's position and selection", back),
            ("the final Home module can only move up", up.isEnabled && !down.isEnabled)
        ]
    }
}
