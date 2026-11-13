import AppKit

@MainActor enum ComposerSizingSelfChecks {
    static func run(app: AppDelegate) -> [(String, Bool)] {
        let controller = ConversationWindow(app: app, session: nil)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let composer = controller.composer
        guard let layout = composer.layoutManager, let container = composer.textContainer, let font = composer.font else { return [("composer sizing has native text layout", false)] }
        let threeLines = (layout.defaultLineHeight(for: font) * 3 + composer.textContainerInset.height * 2).rounded(.up)
        func height(_ text: String) -> CGFloat {
            composer.string = text
            controller.updateComposerHeight()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            return controller.composerHeight.constant
        }
        var results: [(String, Bool)] = []
        results.append(("an empty composer reserves three lines", abs(height("") - threeLines) < 1))
        results.append(("one line keeps the three-line composer height", abs(height("One") - threeLines) < 1))
        let three = height("One\nTwo\nThree")
        layout.ensureLayout(for: container)
        results.append(("three composer lines fit without increasing the default height", abs(three - threeLines) < 1 && layout.usedRect(for: container).height + composer.textContainerInset.height * 2 <= three + 1))
        results.append(("a fourth composer line grows beyond the default", height("One\nTwo\nThree\nFour") > threeLines))
        results.append(("long drafts retain the composer height cap", height(Array(repeating: "Line", count: 40).joined(separator: "\n")) == ComposerMetrics.maximumHeight))
        results.append(("clearing a long draft returns to three lines", abs(height("") - threeLines) < 1))
        // Auto Layout constrains the alignment rect, not the larger frame
        // that AppKit reserves for a button's focus ring and image insets.
        results.append(("composer icon controls stay compact beside the taller editor", [controller.attachButton, controller.emojiButton, controller.sendButton].allSatisfy { abs($0.alignmentRect(forFrame: $0.frame).height - 32) < 1 }))
        controller.manualComposerHeight = 260
        let manual = height("One")
        results.append(("manual height exceeds the automatic cap", manual > ComposerMetrics.maximumHeight))
        results.append(("typing and clearing retain manual height", abs(height("") - manual) < 1 && abs(height("One\nTwo") - manual) < 1))
        controller.composerResizeHandle.onDrag?(-24)
        results.append(("dragging the top edge resizes the inline editor", abs(controller.composerHeight.constant - (manual - 24)) < 1))
        controller.manualComposerHeight = 10_000
        controller.updateComposerHeight(); controller.window?.contentView?.layoutSubtreeIfNeeded()
        results.append(("manual height is bounded by the conversation", controller.composerGlass.frame.height <= (controller.contentController?.view.bounds.height ?? 0) * 0.6 + 2))
        controller.composerResizeHandle.onReset?()
        results.append(("reset restores automatic sizing", controller.manualComposerHeight == nil && abs(height("") - threeLines) < 1))
        return results
    }
}
