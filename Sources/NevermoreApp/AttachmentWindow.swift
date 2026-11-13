import AppKit
import QuickLookUI
import NevermoreCore
import RavenProtocol

/// Owns the download throughout native preview/drag. External applications
/// receive an explicit saved copy, whose lifetime is controlled by the user.
@MainActor final class AttachmentWindow: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let attachment: DownloadedAttachment
    private let active: () -> Bool
    private let reportError: (Error) -> Void
    private let messageLink: URL?
    private let previewKind: AttachmentPreviewKind
    private var savedURL: URL?
    private var observer: NSObjectProtocol?
    private var sharingPicker: NSSharingServicePicker?
    private(set) var savePanel: NSSavePanel?
    private let reveal = NSButton(title: "Reveal Saved File", target: nil, action: nil)
    private let openWith = NSPopUpButton()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var closed = false
    private var exporting = false
    private let save = NSButton(title: "Save As…", target: nil, action: nil)
    private let share = NSButton(title: "Share…", target: nil, action: nil)
    private let makeSavePanel: @MainActor () -> NSSavePanel
    var didClose: (() -> Void)?

    init(attachment: DownloadedAttachment, messageLink: URL?, active: @escaping () -> Bool, reportError: @escaping (Error) -> Void, makeSavePanel: @escaping @MainActor () -> NSSavePanel = { NSSavePanel() }) {
        self.makeSavePanel = makeSavePanel
        self.attachment = attachment; self.messageLink = messageLink; self.active = active; self.reportError = reportError
        previewKind = AttachmentPreviewPolicy.kind(filename: attachment.filename, mimeType: attachment.contentType)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 260), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        panel.title = attachment.filename; panel.isReleasedWhenClosed = false
        super.init(window: panel); panel.delegate = self
        // Quick Look searches the responder chain; standalone windows must
        // include their controller explicitly. The link is non-owning.
        if panel.nextResponder !== self { nextResponder = panel.nextResponder; panel.nextResponder = self }
        let drag = AttachmentDragView(attachment: attachment)
        let preview = NSButton(title: "Quick Look", target: self, action: #selector(previewDownloadedFile))
        preview.isEnabled = previewKind != .unsupported
        save.target = self; save.action = #selector(saveAs)
        share.target = self; share.action = #selector(shareSavedFile(_:))
        let copy = NSButton(title: "Copy Message Link", target: self, action: #selector(copyLink))
        copy.isEnabled = messageLink != nil
        reveal.target = self; reveal.action = #selector(revealSavedFile); reveal.isEnabled = false
        openWith.addItem(withTitle: "Open Saved File With…"); openWith.target = self; openWith.action = #selector(openSavedFile); openWith.isEnabled = false
        let actions = NSStackView(views: [preview, save, share, copy]); actions.spacing = 8
        let savedActions = NSStackView(views: [reveal, openWith]); savedActions.spacing = 8
        detail.stringValue = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file) + (previewKind == .unsupported ? " · Preview unavailable for this file type. Save it to use another app." : " · Drag the file to export a copy.")
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [drag, detail, actions, savedActions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20), drag.widthAnchor.constraint(equalTo: stack.widthAnchor), drag.heightAnchor.constraint(equalToConstant: 64)])
        }
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in guard let self, !self.active() else { return }; self.close() }
        }
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func previewDownloadedFile() {
        guard !closed, active(), previewKind != .unsupported else { return }
        window?.makeKeyAndOrderFront(nil)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil); panel.updateController()
        guard (panel.currentController as AnyObject?) === self else {
            detail.stringValue = "The file is ready. Select this window to preview it."
            return
        }
        panel.reloadData()
    }
    // The SDK's NSObject Quick Look category is nonisolated. Decline any
    // off-main probe before touching AppKit or account-bound state.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated { !closed && active() && previewKind != .unsupported }
    }
    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard !closed, active(), previewKind != .unsupported else { return }
            panel.dataSource = self; panel.delegate = self
        }
    }
    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard (panel.dataSource as AnyObject?) === self else { return }
            panel.dataSource = nil; panel.delegate = nil; panel.orderOut(nil)
        }
    }
    @objc func saveAs() { Task { _ = await saveCopy() } }
    @discardableResult private func saveCopy() async -> URL? {
        guard !closed, active(), !exporting, let parent = window, parent.attachedSheet == nil else { return nil }
        exporting = true; save.isEnabled = false; share.isEnabled = false
        defer { savePanel = nil; exporting = false; save.isEnabled = true; share.isEnabled = true }
        dismissOwnedPreview()
        parent.makeKeyAndOrderFront(nil)
        let panel = makeSavePanel(); panel.nameFieldStringValue = attachment.filename
        savePanel = panel
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
        }
        guard response == .OK, let target = panel.url, !closed, active() else { return nil }
        do {
            let source = attachment
            try await Task.detached(priority: .userInitiated) { try source.export(to: target, replacing: true) }.value
            guard !closed, active() else { return nil }
            savedURL = target; reveal.isEnabled = true
            openWith.removeAllItems(); openWith.addItem(withTitle: "Open Saved File With…")
            if previewKind != .unsupported {
                for app in NSWorkspace.shared.urlsForApplications(toOpen: target) {
                    let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
                    item.representedObject = app; openWith.menu?.addItem(item)
                }
            }
            openWith.isEnabled = openWith.numberOfItems > 1
            detail.stringValue = "Saved as \(target.lastPathComponent). You can reveal, share or drag a copy."
            return target
        } catch { if !closed, active() { reportError(error) }; return nil }
    }
    @objc private func shareSavedFile(_ sender: NSButton) {
        Task {
            guard !closed, active(), !exporting else { return }
            let target: URL?
            if let savedURL { target = savedURL } else { target = await saveCopy() }
            guard !closed, active(), let target else { return }
            // The user-owned saved copy survives private-cache cleanup.
            let picker = NSSharingServicePicker(items: [target]); sharingPicker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
    @objc private func revealSavedFile() {
        guard !closed, active(), let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }
    @objc private func openSavedFile() {
        defer { openWith.selectItem(at: 0) }
        guard !closed, active(), let savedURL, let app = openWith.selectedItem?.representedObject as? URL else { return }
        NSWorkspace.shared.open([savedURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error { Task { @MainActor [weak self] in guard let self, !self.closed, self.active() else { return }; self.reportError(error) } }
        }
    }
    @objc private func copyLink() {
        guard !closed, active(), let messageLink else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(messageLink.absoluteString, forType: .string)
    }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        guard Thread.isMainThread else { return 0 }
        return MainActor.assumeIsolated { !closed && active() ? 1 : 0 }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard Thread.isMainThread else { return nil }
        let url: URL? = MainActor.assumeIsolated { !closed && active() && index == 0 ? attachment.url : nil }
        return url as NSURL?
    }
    private func dismissOwnedPreview() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), (panel.dataSource as AnyObject?) === self {
            // Unlinking the responder can change currentController before
            // Quick Look releases its data source. Clear our source first.
            panel.dataSource = nil; panel.delegate = nil; panel.orderOut(nil)
        }
    }
    override func close() {
        let panel = savePanel; savePanel = nil
        panel?.cancel(nil)
        super.close()
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; sharingPicker = nil
        savePanel?.cancel(nil); savePanel = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        dismissOwnedPreview()
        if window?.nextResponder === self { window?.nextResponder = nextResponder }; nextResponder = nil
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.updateController() }
        didClose?(); didClose = nil
    }
}
