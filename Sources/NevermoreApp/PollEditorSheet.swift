import AppKit
import NevermoreCore

@MainActor final class PollEditorSheet: NSObject, NSWindowDelegate {
    private weak var parent: NSWindow?
    let panel: NSPanel
    let question = NSTextField()
    let options = NSTextView()
    let multiple = NSButton(checkboxWithTitle: "Allow multiple choices", target: nil, action: nil)
    let anonymous = NSButton(checkboxWithTitle: "Keep voters anonymous", target: nil, action: nil)
    let limit = NSPopUpButton()
    let timed = NSButton(checkboxWithTitle: "Close at a specific time", target: nil, action: nil)
    let deadline = NSDatePicker()
    let status = NSTextField(wrappingLabelWithString: "")
    private var continuation: CheckedContinuation<PollDraft?, Never>?
    private var finished = false
    private var observer: NSObjectProtocol?

    static func create(on parent: NSWindow, timeZone: TimeZone) async throws -> PollDraft? {
        guard parent.attachedSheet == nil else { throw AppError.message("Finish the current sheet before creating a poll.") }
        let controller = PollEditorSheet(parent: parent, timeZone: timeZone)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { controller.present($0) }
        } onCancel: { Task { @MainActor in controller.finish(nil) } }
    }
    init(parent: NSWindow, timeZone: TimeZone) {
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(); panel.title = "Create Poll"; panel.isReleasedWhenClosed = false; panel.delegate = self
        question.placeholderString = "What would you like to ask?"; question.setAccessibilityLabel("Poll question")
        options.isRichText = false; options.font = .systemFont(ofSize: 13); options.isVerticallyResizable = true; options.isHorizontallyResizable = false; options.autoresizingMask = .width; options.textContainer?.widthTracksTextView = true; options.textContainerInset = NSSize(width: 8, height: 8)
        options.setAccessibilityLabel("Poll options, one per line")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = options
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        multiple.target = self; multiple.action = #selector(settingsChanged)
        timed.target = self; timed.action = #selector(settingsChanged)
        limit.addItem(withTitle: "No limit")
        for count in 2...19 { limit.addItem(withTitle: "Up to \(count)") }
        limit.setAccessibilityLabel("Maximum choices")
        deadline.datePickerStyle = .textFieldAndStepper; deadline.datePickerElements = [.yearMonthDay, .hourMinute]; deadline.timeZone = timeZone; deadline.dateValue = Date().addingTimeInterval(86400); deadline.minDate = Date(); deadline.setAccessibilityLabel("Poll closing time in site timezone")
        let timing = NSStackView(views: [deadline, NSTextField(labelWithString: timeZone.identifier)]); timing.spacing = 8
        let choices = NSStackView(views: [multiple, limit]); choices.spacing = 8
        status.textColor = .systemRed
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let accept = NSButton(title: "Create Poll", target: self, action: #selector(accept)); accept.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, accept]); buttons.spacing = 8
        let instructions = NSTextField(wrappingLabelWithString: "Enter 2 to 20 different options, one per line. A multiple-choice limit must be at least 2 and smaller than the number of options.")
        instructions.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [NSTextField(labelWithString: "Question"), question, NSTextField(labelWithString: "Options"), instructions, scroll, choices, anonymous, timed, timing, status, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20), question.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), instructions.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        }
        panel.initialFirstResponder = question; settingsChanged()
    }
    @objc private func settingsChanged() {
        limit.isEnabled = multiple.state == .on
        deadline.isEnabled = timed.state == .on
        // The picker was created when the sheet opened; refresh the floor
        // when it becomes relevant. accept() still rejects a deadline that
        // has passed since the reader chose it.
        if timed.state == .on { deadline.minDate = Date() }
    }
    private func present(_ continuation: CheckedContinuation<PollDraft?, Never>) {
        guard let parent, !finished else { continuation.resume(returning: nil); return }
        self.continuation = continuation
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in self?.finish(nil) } }
        parent.beginSheet(panel) { [weak self] _ in self?.finish(nil) }
    }
    @objc func accept() {
        do {
            let rows = options.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let finite = limit.indexOfSelectedItem == 0 ? nil : Optional(limit.indexOfSelectedItem + 1)
            let mode: PollDraft.ChoiceMode = multiple.state == .on ? .multiple(limit: finite) : .single
            let result = try PollDraft(question: question.stringValue, options: rows, choiceMode: mode, privacy: anonymous.state == .on ? .anonymous : .named, deadline: timed.state == .on ? deadline.dateValue : nil)
            finish(result)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func cancel() { finish(nil) }
    private func finish(_ result: PollDraft?) {
        guard !finished else { return }; finished = true
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let parent, parent.attachedSheet === panel { parent.endSheet(panel) }
        panel.orderOut(nil)
        let pending = continuation; continuation = nil; pending?.resume(returning: result)
    }
}
