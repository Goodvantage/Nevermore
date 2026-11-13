import AppKit
import UniformTypeIdentifiers
import RavenProtocol

/// The provider retains this immutable delegate through userInfo, because
/// AppKit's delegate property is weak. A completed drag can outlive its view.
final class AttachmentFilePromise: NSObject, NSFilePromiseProviderDelegate {
    private let attachment: DownloadedAttachment
    private let queue: OperationQueue
    init(_ attachment: DownloadedAttachment) {
        self.attachment = attachment
        queue = OperationQueue(); queue.name = "Nevermore attachment export"; queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        super.init()
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { attachment.filename }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        do { try attachment.export(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}

@MainActor final class AttachmentDragView: NSView, NSDraggingSource {
    private let attachment: DownloadedAttachment
    private let icon: NSImage
    private var start: NSPoint?
    init(attachment: DownloadedAttachment) {
        self.attachment = attachment; icon = NSWorkspace.shared.icon(forFile: attachment.url.path)
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Attachment: \(attachment.filename)")
        setAccessibilityHelp("Drag this file to another app or folder to export a copy. Save As is also available.")
        toolTip = "Drag \(attachment.filename) to export a copy"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon.draw(in: NSRect(x: 0, y: 8, width: 48, height: 48))
        let text = NSAttributedString(string: attachment.filename, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium), .foregroundColor: NSColor.labelColor])
        text.draw(with: NSRect(x: 64, y: 20, width: max(0, bounds.width - 64), height: 32), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        self.start = nil
        let delegate = AttachmentFilePromise(attachment)
        let proposed = UTType(filenameExtension: attachment.url.pathExtension)
        let type = proposed?.conforms(to: .data) == true ? proposed! : .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate); provider.userInfo = delegate
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { start = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
