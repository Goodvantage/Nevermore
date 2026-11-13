import AppKit

@MainActor private final class ChoiceDocumentView: NSView { override var isFlipped: Bool { true } }

/// A native attached choice sheet used where the app needs one or more selections
/// without leaving the current window. The sheet owns its lifecycle: it stays alive
/// until the continuation finishes exactly once, closes through AppKit sheet APIs,
/// and dismisses on the main actor when the awaiting task is cancelled.
@MainActor final class ChoiceSheet: NSObject, NSWindowDelegate {
    struct Choice: Sendable, Hashable {
        let id: String
        let title: String
        let detail: String

        init(id: String, title: String, detail: String = "") {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    private let sheet: NSPanel
    private weak var parent: NSWindow?
    private let choices: [Choice]
    private let allowsMultiple: Bool
    private let maximum: Int?
    private var optionButtons: [String: NSButton] = [:]
    private var optionOrder: [String] = []
    private var selectedIDs = Set<String>()
    private var continuation: CheckedContinuation<[String]?, Never>?
    private var finished = false

    private let chooseButton = NSButton(title: "Choose", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private init(title: String, prompt: String, choices: [Choice], selected: Set<String>, allowsMultiple: Bool, maximum: Int?) {
        self.choices = choices
        self.allowsMultiple = allowsMultiple
        self.maximum = maximum
        sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        sheet.title = title
        sheet.delegate = self
        sheet.isFloatingPanel = false
        sheet.hidesOnDeactivate = false

        let promptLabel = NSTextField(wrappingLabelWithString: prompt)
        promptLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptLabel.textColor = .labelColor
        promptLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let optionsStack = NSStackView()
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        let validSelection = selected.intersection(Set(choices.map(\.id)))
        for choice in choices {
            let button = NSButton(checkboxWithTitle: choice.title, target: self, action: #selector(toggleOption(_:)))
            if !allowsMultiple {
                button.setButtonType(.radio)
            }
            button.identifier = NSUserInterfaceItemIdentifier(choice.id)
            button.state = validSelection.contains(choice.id) ? .on : .off
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            button.setAccessibilityLabel(choice.detail.isEmpty ? choice.title : "\(choice.title). \(choice.detail)")

            if choice.detail.isEmpty {
                optionsStack.addArrangedSubview(button)
            } else {
                let detail = NSTextField(wrappingLabelWithString: choice.detail)
                detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                detail.textColor = .secondaryLabelColor
                detail.setContentCompressionResistancePriority(.required, for: .vertical)
                let group = NSStackView(views: [button, detail])
                group.orientation = .vertical
                group.alignment = .leading
                group.spacing = 2
                optionsStack.addArrangedSubview(group)
            }
            optionButtons[choice.id] = button
            optionOrder.append(choice.id)
            if button.state == .on { selectedIDs.insert(choice.id) }
        }

        let optionsContainer = ChoiceDocumentView()
        optionsContainer.translatesAutoresizingMaskIntoConstraints = false
        optionsContainer.addSubview(optionsStack)
        NSLayoutConstraint.activate([
            optionsStack.leadingAnchor.constraint(equalTo: optionsContainer.leadingAnchor),
            optionsStack.trailingAnchor.constraint(equalTo: optionsContainer.trailingAnchor),
            optionsStack.topAnchor.constraint(equalTo: optionsContainer.topAnchor),
            optionsStack.bottomAnchor.constraint(equalTo: optionsContainer.bottomAnchor),
            optionsStack.widthAnchor.constraint(equalTo: optionsContainer.widthAnchor)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.documentView = optionsContainer
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelChoice))
        cancelButton.keyEquivalent = "\u{1b}"
        chooseButton.title = "Choose"
        chooseButton.target = self
        chooseButton.action = #selector(acceptChoice)
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), cancelButton, chooseButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let content = NSStackView(views: [promptLabel, scroll, statusLabel, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView?.addSubview(content)
        if let root = sheet.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
                content.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
                scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: content.widthAnchor)
            ])
        }

        // Width 600; height fits up to 10 visible choices, then scrolls.
        let visibleRows = min(max(choices.count, 1), 10)
        let estimated = Double(visibleRows) * 24.0 + max(0, Double(visibleRows - 1)) * 8.0 + 16.0
        let scrollHeight = min(max(estimated, 60), 360)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: CGFloat(scrollHeight)),
            optionsContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        sheet.setContentSize(NSSize(width: 600, height: scrollHeight + 150))
        sheet.contentView?.layoutSubtreeIfNeeded()

        updateControls()
        sheet.initialFirstResponder = chooseButton.isEnabled ? chooseButton : cancelButton
        sheet.defaultButtonCell = chooseButton.cell as? NSButtonCell
    }

    static func choose(
        title: String,
        prompt: String,
        choices: [Choice],
        selected: Set<String> = [],
        allowsMultiple: Bool = true,
        maximum: Int? = nil,
        on parent: NSWindow
    ) async throws -> [String]? {
        if choices.count > 500 {
            throw AppError.message("Too many choices to present safely (\(choices.count)). The limit is 500.")
        }
        var seen = Set<String>()
        for choice in choices {
            guard !choice.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("A choice has no identifier.") }
            if !seen.insert(choice.id).inserted {
                throw AppError.message("Duplicate choice identifier '\(choice.id)'. Choice identifiers must be unique.")
            }
        }
        if let maximum, maximum < 1 {
            throw AppError.message("The maximum selection count must be at least 1.")
        }
        let initial = selected.intersection(seen)
        guard initial.count <= (allowsMultiple ? maximum ?? choices.count : 1) else { throw AppError.message("The initial selection exceeds the selection limit.") }
        guard !choices.isEmpty else { throw AppError.message("No choices are available.") }
        guard parent.attachedSheet == nil else { throw AppError.message("Finish the current dialog before choosing items.") }
        try Task.checkCancellation()

        let controller = ChoiceSheet(
            title: title,
            prompt: prompt,
            choices: choices,
            selected: selected,
            allowsMultiple: allowsMultiple,
            maximum: maximum
        )
        return await controller.present(on: parent)
    }

    private func present(on window: NSWindow) async -> [String]? {
        parent = window
        NotificationCenter.default.addObserver(self, selector: #selector(parentClosed), name: NSWindow.willCloseNotification, object: window)
        defer { NotificationCenter.default.removeObserver(self) }
        let choice = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                window.beginSheet(self.sheet) { [weak self] _ in
                    // Safety net: if AppKit ends the sheet without an explicit finish path.
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(nil)
            }
        }
        _ = self // keep controller alive through presentation
        return choice
    }

    @objc private func toggleOption(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if !allowsMultiple {
            if sender.state == .on {
                selectedIDs = [id]
                for (otherID, button) in optionButtons where otherID != id {
                    button.state = .off
                }
            } else {
                // Native radio groups can clear the pressed item; do not auto-select another.
                selectedIDs.remove(id)
            }
        } else {
            if sender.state == .on {
                if let maximum, selectedIDs.count >= maximum, !selectedIDs.contains(id) {
                    sender.state = .off
                    NSSound.beep()
                } else {
                    selectedIDs.insert(id)
                }
            } else {
                selectedIDs.remove(id)
            }
        }
        updateControls()
    }

    @objc private func acceptChoice() {
        guard !selectedIDs.isEmpty else { return }
        finish(orderedSelection())
    }

    @objc private func cancelChoice() {
        finish(nil)
    }
    @objc private func parentClosed(_ notification: Notification) { finish(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func orderedSelection() -> [String] {
        optionOrder.filter { selectedIDs.contains($0) }
    }

    private func updateControls() {
        chooseButton.isEnabled = !selectedIDs.isEmpty
        sheet.defaultButtonCell = chooseButton.isEnabled ? (chooseButton.cell as? NSButtonCell) : nil

        var parts: [String] = ["\(selectedIDs.count) selected"]
        if let maximum { parts.append("limit \(maximum)") }
        if !allowsMultiple { parts.append("choose 1") }
        if selectedIDs.isEmpty { parts.append("select at least 1 to continue") }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    private func finish(_ result: [String]?) {
        guard !finished else { return }
        finished = true
        if let parent {
            parent.endSheet(sheet)
        }
        sheet.orderOut(nil)
        continuation?.resume(returning: result)
        continuation = nil
    }
}
