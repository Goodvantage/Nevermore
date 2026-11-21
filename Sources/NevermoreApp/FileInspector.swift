import AppKit
import QuickLookUI
import NevermoreCore
import RavenProtocol

/// The message a file came with, as the File panel describes it.
struct FileInspectorSource {
    let messageID: String
    let channelID: String
    let filename: String
    let sender: String
    let sent: String
    let conversation: String?
    let messageLink: URL?
}

/// The File panel: a clicked attachment's preview, details and actions in
/// the conversation window's inspector pane. It owns the private download
/// while it shows it; full-size Quick Look, Save As and Share use that copy.
/// Like the attachment window, it hands other apps only a saved copy.
@MainActor final class FileInspector: NSViewController {
    /// Below this window width a click previews in Quick Look instead.
    static let minimumWindowWidth = ThreadInspector.minimumWindowWidth
    let source: FileInspectorSource
    private(set) var attachment: DownloadedAttachment?
    private(set) var savedURL: URL?
    private(set) var savePanel: NSSavePanel?
    private(set) var isDetached = false
    /// The live preview, while the file is one that may be previewed.
    private(set) var previewView: QLPreviewView?
    var onQuickLook: ((DownloadedAttachment) -> Void)?
    var onShowMessage: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// The reader asked to download a failed file again.
    var onRetry: ((_ thenSave: Bool) -> Void)?

    private let active: () -> Bool
    private let reportError: (Error) -> Void
    private let makeSavePanel: @MainActor () -> NSSavePanel
    private var previewKind: AttachmentPreviewKind
    /// The download failed and the panel offers an explicit retry.
    private(set) var hasFailed = false
    private var exporting = false
    private var observer: NSObjectProtocol?
    private var sharingPicker: NSSharingServicePicker?

    private let previewArea = NSView()
    private let placeholder = NSStackView()
    private let placeholderIcon = NSImageView()
    private let placeholderText = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let nameRow = NSStackView()
    private let details = NSStackView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let quickLookButton = NSButton(title: "Quick Look", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save As…", target: nil, action: nil)
    private let shareButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: nil, action: nil)
    private let savedActions = NSStackView()
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let openWith = NSPopUpButton()

    init(source: FileInspectorSource, active: @escaping () -> Bool, reportError: @escaping (Error) -> Void, makeSavePanel: @escaping @MainActor () -> NSSavePanel = { NSSavePanel() }) {
        self.source = source; self.active = active; self.reportError = reportError; self.makeSavePanel = makeSavePanel
        previewKind = AttachmentPreviewPolicy.kind(filename: source.filename, mimeType: nil)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.setAccessibilityLabel("File: \(source.filename)")
        let title = NSTextField(labelWithString: "File"); title.font = .preferredFont(forTextStyle: .headline)
        shareButton.target = self; shareButton.action = #selector(shareFile(_:))
        shareButton.isBordered = false; shareButton.contentTintColor = .secondaryLabelColor; shareButton.toolTip = "Share a saved copy"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close File")!, target: self, action: #selector(closePanel))
        close.isBordered = false; close.contentTintColor = .tertiaryLabelColor; close.symbolConfiguration = .init(pointSize: 14, weight: .regular); close.toolTip = "Close"
        let header = NSStackView(views: [title, NSView(), shareButton, close]); header.orientation = .horizontal; header.spacing = 10

        // The preview takes the height the details and actions leave.
        previewArea.wantsLayer = true; previewArea.layer?.cornerRadius = 8; previewArea.layer?.masksToBounds = true
        previewArea.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewArea.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        placeholderIcon.image = NSWorkspace.shared.icon(for: .data); placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
        placeholderText.alignment = .center; placeholderText.textColor = .secondaryLabelColor
        spinner.style = .spinning; spinner.controlSize = .small
        retryButton.target = self; retryButton.action = #selector(retryDownload); retryButton.toolTip = "Download the file again"
        placeholder.orientation = .vertical; placeholder.alignment = .centerX; placeholder.spacing = 10
        placeholder.setViews([placeholderIcon, spinner, placeholderText, retryButton], in: .center)
        placeholder.translatesAutoresizingMaskIntoConstraints = false; previewArea.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholderIcon.widthAnchor.constraint(equalToConstant: 64), placeholderIcon.heightAnchor.constraint(equalToConstant: 64),
            placeholder.centerXAnchor.constraint(equalTo: previewArea.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: previewArea.widthAnchor, constant: -24),
            placeholderText.widthAnchor.constraint(lessThanOrEqualTo: previewArea.widthAnchor, constant: -24),
        ])

        let name = NSTextField(wrappingLabelWithString: source.filename)
        name.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold); name.isSelectable = true; name.maximumNumberOfLines = 3
        nameRow.orientation = .vertical; nameRow.alignment = .leading; nameRow.setViews([name], in: .top)

        details.orientation = .vertical; details.alignment = .leading; details.spacing = 4
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor

        quickLookButton.target = self; quickLookButton.action = #selector(showQuickLook); quickLookButton.toolTip = "Show the file full size (Space or ⌘Y)"
        saveButton.target = self; saveButton.action = #selector(saveAs); saveButton.toolTip = "Save a copy (⇧⌘S)"
        let showMessage = NSButton(title: "Show Message", target: self, action: #selector(showInConversation)); showMessage.toolTip = "Scroll the conversation to the message with this file"
        let copyLink = NSButton(title: "Copy Link", target: self, action: #selector(copyMessageLink)); copyLink.toolTip = "Copy a link to the message"
        copyLink.isEnabled = source.messageLink != nil
        revealButton.target = self; revealButton.action = #selector(revealSavedFile)
        openWith.pullsDown = true; openWith.addItem(withTitle: "Open With"); openWith.target = self; openWith.action = #selector(openSavedFile)
        let primary = buttonRow([quickLookButton, saveButton])
        let secondary = buttonRow([showMessage, copyLink])
        savedActions.orientation = .horizontal; savedActions.distribution = .fillEqually; savedActions.spacing = 8
        savedActions.setViews([revealButton, openWith], in: .leading); savedActions.isHidden = true

        let divider = NSBox(); divider.boxType = .separator
        let stack = NSStackView(views: [header, previewArea, nameRow, details, divider, primary, secondary, savedActions, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: previewArea)
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        for row in [header, previewArea, nameRow, details, divider, primary, secondary, savedActions, note] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            previewArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        showDownloading()
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
        return row
    }

    /// Starts watching the account; a stopped account or a revoked
    /// conversation closes the panel and drops the private file.
    func start() {
        loadViewIfNeeded()
        guard observer == nil, !isDetached else { return }
        observer = NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.isDetached, !self.active() else { return }; self.closePanel() }
        }
    }

    // MARK: States

    /// Puts the panel back into its loading state for a retry.
    private func showDownloading() {
        hasFailed = false
        placeholderIcon.isHidden = true
        spinner.isHidden = false; spinner.startAnimation(nil)
        placeholderText.stringValue = "Downloading…"
        renderDetails(size: nil, dimensions: nil)
        updateButtons()
    }

    /// Shows the downloaded file. A file the preview policy refuses keeps its
    /// icon: active formats are never rendered, only saved on request.
    /// A panel shows one file; later calls are ignored.
    func show(_ attachment: DownloadedAttachment) {
        guard !isDetached, self.attachment == nil else { return }
        loadViewIfNeeded()
        hasFailed = false
        self.attachment = attachment
        previewKind = AttachmentPreviewPolicy.kind(filename: attachment.filename, mimeType: attachment.contentType)
        spinner.stopAnimation(nil); spinner.isHidden = true
        let drag = AttachmentDragView(attachment: attachment)
        drag.heightAnchor.constraint(equalToConstant: 64).isActive = true
        nameRow.setViews([drag], in: .top)
        drag.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true
        if previewKind != .unsupported, let preview = QLPreviewView(frame: previewArea.bounds, style: .normal) {
            preview.autostarts = false; preview.shouldCloseWithWindow = false
            preview.autoresizingMask = [.width, .height]
            preview.previewItem = attachment.url as NSURL
            preview.setAccessibilityLabel("Preview of \(attachment.filename)")
            previewArea.addSubview(preview); previewView = preview
            placeholder.isHidden = true
        } else {
            placeholderIcon.image = NSWorkspace.shared.icon(forFile: attachment.url.path); placeholderIcon.isHidden = false
            placeholderText.stringValue = "Nevermore doesn’t preview this kind of file. Save a copy to open it outside Nevermore."
        }
        let pixels = previewKind == .image ? AttachmentDetails.pixelSize(ofImageAt: attachment.url) : nil
        renderDetails(size: ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file), dimensions: pixels.map { AttachmentDetails.dimensionsText(width: $0.width, height: $0.height) })
        note.stringValue = "Drag the file to export a copy."
        updateButtons()
    }

    /// The download failed; the message and its details stay in view.
    func showFailure(_ error: Error) {
        guard !isDetached else { return }
        loadViewIfNeeded()
        hasFailed = true
        spinner.stopAnimation(nil); spinner.isHidden = true
        placeholderIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil); placeholderIcon.isHidden = false
        placeholderText.stringValue = "The file could not be downloaded. \(error.localizedDescription)"
        updateButtons()
    }

    private func renderDetails(size: String?, dimensions: String?) {
        var rows: [(String, String)] = [("Kind", AttachmentDetails.kind(filename: attachment?.filename ?? source.filename, mimeType: attachment?.contentType))]
        if let size { rows.append(("Size", size)) }
        if let dimensions { rows.append(("Dimensions", dimensions)) }
        rows.append(("From", source.sender)); rows.append(("Sent", source.sent))
        if let conversation = source.conversation { rows.append(("In", conversation)) }
        details.setViews(rows.map { label, value in
            let key = NSTextField(labelWithString: label); key.textColor = .secondaryLabelColor; key.alignment = .right
            key.widthAnchor.constraint(equalToConstant: 78).isActive = true
            let field = NSTextField(wrappingLabelWithString: value); field.isSelectable = true; field.setAccessibilityLabel(label)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [key, field]); row.orientation = .horizontal; row.alignment = .firstBaseline; row.spacing = 10
            return row
        }, in: .top)
        for row in details.views { row.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true }
    }

    private func updateButtons() {
        let ready = attachment != nil && !isDetached && !exporting
        quickLookButton.isEnabled = ready && previewKind != .unsupported
        saveButton.isEnabled = ready
        shareButton.isEnabled = ready
        savedActions.isHidden = savedURL == nil
        openWith.isEnabled = openWith.numberOfItems > 1
        retryButton.isHidden = !hasFailed || isDetached
    }

    // MARK: Actions

    @objc func showQuickLook() {
        guard !isDetached, active(), let attachment, previewKind != .unsupported else { return }
        onQuickLook?(attachment)
    }

    @objc func saveAs() { Task { _ = await saveCopy() } }

    /// Retries only from the failed state; a download already in flight owns
    /// the single request.
    @objc private func retryDownload() { retry(thenSave: false) }

    func retry(thenSave: Bool) {
        guard !isDetached, hasFailed, active(), let onRetry else { return }
        showDownloading()
        onRetry(thenSave)
    }

    @discardableResult func saveCopy() async -> URL? {
        guard !isDetached, active(), !exporting, let attachment, let parent = view.window else { return nil }
        exporting = true; updateButtons()
        defer { savePanel = nil; exporting = false; updateButtons() }
        let panel = makeSavePanel(); savePanel = panel
        do {
            guard let target = try await AttachmentExport.saveCopy(of: attachment, using: panel, over: parent, isCurrent: { [weak self] in self.map { !$0.isDetached && $0.active() } ?? false }), !isDetached else { return nil }
            savedURL = target
            openWith.removeAllItems(); openWith.addItem(withTitle: "Open With")
            if previewKind != .unsupported { for item in AttachmentExport.openWithItems(for: target) { openWith.menu?.addItem(item) } }
            note.stringValue = "Saved as \(target.lastPathComponent)."
            return target
        } catch {
            if !isDetached, active() { reportError(error) }
            return nil
        }
    }

    @objc private func shareFile(_ sender: NSButton) {
        Task {
            guard !isDetached, active(), !exporting else { return }
            let target: URL?
            if let savedURL { target = savedURL } else { target = await saveCopy() }
            guard !isDetached, active(), let target else { return }
            // The user-owned saved copy survives private-cache cleanup.
            let picker = NSSharingServicePicker(items: [target]); sharingPicker = picker
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func revealSavedFile() {
        guard !isDetached, active(), let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    @objc private func openSavedFile() {
        defer { openWith.selectItem(at: 0) }
        guard !isDetached, active(), let savedURL, let app = openWith.selectedItem?.representedObject as? URL else { return }
        NSWorkspace.shared.open([savedURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor [weak self] in guard let self, !self.isDetached, self.active() else { return }; self.reportError(error) }
        }
    }

    @objc private func showInConversation() { guard !isDetached, active() else { return }; onShowMessage?(source.messageID) }

    @objc private func copyMessageLink() {
        guard !isDetached, active(), let link = source.messageLink else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
        note.stringValue = "Link copied."
    }

    @objc func closePanel() { onClose?() }
    override func cancelOperation(_ sender: Any?) { closePanel() }

    /// Ends the panel: cancels a save sheet, stops the preview and releases
    /// the private file. Safe to call more than once.
    func detach() {
        guard !isDetached else { return }
        isDetached = true
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        let panel = savePanel; savePanel = nil; panel?.cancel(nil)
        sharingPicker = nil
        previewView?.close(); previewView?.removeFromSuperview(); previewView = nil
        attachment = nil; savedURL = nil
        onQuickLook = nil; onShowMessage = nil; onClose = nil; onRetry = nil
        if isViewLoaded { spinner.stopAnimation(nil); updateButtons() }
    }
}
