import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum ConversationDropSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreDropCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "drop@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("drop-channel"), "channel_name": .string("Drop fixture")]))
        session.channels = [channel]
        try await session.store.cacheChannels([channel])
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        await controller.loadTask?.value; await controller.renderTask?.value
        guard let window = controller.window, let destination = window as? any NSDraggingDestination else {
            return [("the entire conversation window is a file-drop destination", false)]
        }
        var results: [(String, Bool)] = []
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = directory.appendingPathComponent("dropped.txt")
        try Data("Nevermore file drop fixture\n".utf8).write(to: file)
        pasteboard.writeObjects([file as NSURL])
        let drag = FileDragFixture(window: window, pasteboard: pasteboard)
        controller.composer.string = "Keep this unsent draft"
        var sends = 0
        controller.composer.onSend = { sends += 1 }
        for (name, view) in [("transcript", controller.transcript as NSView), ("sidebar", controller.sidebar as NSView), ("composer margin", controller.composerGlass as NSView)] {
            drag.draggingLocation = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let before = controller.attachments.count
            let accepted = destination.draggingEntered?(drag) == .copy && destination.draggingUpdated?(drag) == .copy && destination.prepareForDragOperation?(drag) == true && destination.performDragOperation?(drag) == true
            for task in controller.promisedReceives.values { await task.value }
            await controller.saveTask?.value
            results.append(("dropping a file over the \(name) stages it once without replacing or sending the draft", accepted && controller.attachments.count == before + 1 && controller.composer.string == "Keep this unsent draft" && sends == 0))
        }
        results.append(("the read-only transcript lets file drags reach the window", controller.transcript.registeredDraggedTypes.isEmpty))
        controller.showWindow(nil)
        controller.search.stringValue = "Keep this query"
        window.makeFirstResponder(controller.search)
        if let editor = controller.search.currentEditor() as? NSTextView {
            let before = controller.attachments.count
            drag.draggingLocation = controller.search.convert(.zero, to: nil)
            let accepted = editor.draggingEntered(drag) == .copy && editor.prepareForDragOperation(drag) && editor.performDragOperation(drag)
            for task in controller.promisedReceives.values { await task.value }
            await controller.saveTask?.value
            results.append(("a file dropped on the active search editor becomes an attachment without changing the query or draft", accepted && controller.attachments.count == before + 1 && editor.string == "Keep this query" && controller.composer.string == "Keep this unsent draft" && sends == 0))
            controller.editing = RavenMessage(raw: .object(["name": .string("editing"), "channel_id": .string(channel.id)]))
            results.append(("the search editor does not insert file paths when attachments are unavailable", editor.draggingEntered(drag) == [] && !editor.performDragOperation(drag) && editor.string == "Keep this query"))
            controller.editing = nil
        } else { results.append(("the search control installs its native field editor", false)) }
        controller.search.stringValue = ""
        window.makeFirstResponder(controller.composer)
        drag.draggingSourceOperationMask = .move
        results.append(("file drops require the source to allow copying", destination.draggingEntered?(drag) == [] && destination.performDragOperation?(drag) == false))
        drag.draggingSourceOperationMask = .copy
        controller.editing = RavenMessage(raw: .object(["name": .string("editing"), "channel_id": .string(channel.id)]))
        results.append(("window-wide file drops are declined while editing an existing message", destination.draggingEntered?(drag) == [] && destination.performDragOperation?(drag) == false))
        controller.editing = nil
        controller.composer.isEditable = false
        results.append(("window-wide file drops respect a disabled composer", destination.draggingEntered?(drag) == [] && destination.performDragOperation?(drag) == false))
        controller.composer.isEditable = true
        pasteboard.clearContents(); pasteboard.setString("Plain text", forType: .string)
        results.append(("text drags outside the composer are not attachments", destination.draggingEntered?(drag) == [] && destination.performDragOperation?(drag) == false))
        pasteboard.clearContents(); pasteboard.writeObjects([URL(string: "https://example.invalid/file.txt")! as NSURL])
        results.append(("web URL drags outside the composer are not files", destination.draggingEntered?(drag) == [] && destination.performDragOperation?(drag) == false))
        pasteboard.declareTypes([.init("com.apple.pasteboard.promised-file-content-type"), .init("com.apple.pasteboard.promised-file-url")], owner: nil)
        results.append(("window-wide drops also advertise file-promise reception", destination.draggingEntered?(drag) == .copy))
        controller.close()
        results.append(("closed conversation windows decline file drops", destination.draggingEntered?(drag) == []))
        return results
    }
}

@MainActor private final class FileDragFixture: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, pasteboard: NSPasteboard) { draggingDestinationWindow = window; draggingPasteboard = pasteboard }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
