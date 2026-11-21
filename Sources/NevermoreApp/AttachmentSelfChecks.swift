import AppKit
import QuickLookUI
import RavenProtocol
import Synchronization

@MainActor enum AttachmentSelfChecks {
    static func run(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Attachment self-checks require the local fixture runner.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreAttachmentCheck-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RavenClient(origin: origin, tokens: nil, clientID: "local-fixture", accountID: UUID())
        var attachment: DownloadedAttachment? = try await client.download(origin.appendingPathComponent("fixture.txt"), to: root)
        var failures: [Error] = [], results: [(String, Bool)] = []
        let exportArgument = CommandLine.arguments.firstIndex(of: "--attachment-export-directory")
        let exportDirectory: URL?
        if let exportArgument, CommandLine.arguments.indices.contains(exportArgument + 1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[exportArgument + 1], isDirectory: true)
            guard directory.lastPathComponent.hasPrefix("NevermoreNativeExport-") else { throw AppError.message("Invalid external attachment fixture directory.") }
            exportDirectory = directory
        } else { exportDirectory = nil }
        var controller: AttachmentWindow? = AttachmentWindow(attachment: attachment!, messageLink: nil, active: { true }, reportError: { failures.append($0); print("Attachment fixture error: \($0.localizedDescription)"); fflush(nil) }, makeSavePanel: {
            let panel = NSSavePanel()
            if let exportDirectory { panel.directoryURL = exportDirectory }
            return panel
        })
        controller?.showWindow(nil); controller?.window?.contentView?.layoutSubtreeIfNeeded()
        if let content = controller?.window?.contentView {
            let controls = InteractionSelfChecks.descendants(content, of: NSButton.self)
            results.append(("attachment actions fit their native window", controls.count >= 6 && controls.allSatisfy { content.bounds.contains($0.convert($0.bounds, to: content)) }))
        } else { results.append(("attachment actions fit their native window", false)) }
        NSApp.activate(ignoringOtherApps: true); controller?.window?.makeKeyAndOrderFront(nil)
        for _ in 0..<100 { if controller?.window?.isKeyWindow == true { break }; try await Task.sleep(for: .milliseconds(10)) }
        controller?.previewDownloadedFile()
        let probing = controller!
        let backgroundDeclined = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: !probing.acceptsPreviewPanelControl(nil) && probing.numberOfPreviewItems(in: nil) == 0 && probing.previewPanel(nil, previewItemAt: 0) == nil)
            }
        }
        results.append(("Quick Look callbacks decline background access without touching AppKit", backgroundDeclined))
        results.append(("safe downloaded text opens in native Quick Look", QLPreviewPanel.shared()?.isVisible == true && (QLPreviewPanel.shared()?.dataSource as AnyObject?) === controller))
        if let exportArgument {
            guard CommandLine.arguments.indices.contains(exportArgument + 1) else { throw AppError.message("Missing external attachment export fixture directory.") }
            let directory = URL(fileURLWithPath: CommandLine.arguments[exportArgument + 1], isDirectory: true)
            guard directory.lastPathComponent.hasPrefix("NevermoreNativeExport-") else { throw AppError.message("Invalid external attachment fixture directory.") }
            print("NEVERMORE_SAVE_PANEL_READY"); fflush(nil)
            controller?.saveAs()
            var saved = false
            for _ in 0..<1200 {
                saved = controller?.window?.contentView.map { InteractionSelfChecks.descendants($0, of: NSButton.self).contains { $0.title == "Reveal Saved File" && $0.isEnabled } } == true
                if saved || !failures.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            results.append(("Save As publishes a quarantined file outside the sandbox", saved && (try? directory.appendingPathComponent("fixture.txt").resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) != nil))
            if saved {
                controller?.saveAs()
                for _ in 0..<200 {
                    if controller?.window?.attachedSheet != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        var delegate: AttachmentFilePromise? = AttachmentFilePromise(attachment!)
        let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: delegate!)
        provider.userInfo = delegate; delegate = nil
        let parent = controller?.window
        let hadPendingSave = parent?.attachedSheet != nil
        controller?.close()
        for _ in 0..<200 {
            if parent?.attachedSheet == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if exportArgument != nil { results.append(("closing an attachment window cancels its pending save sheet", hadPendingSave && parent?.attachedSheet == nil)) }
        controller = nil; attachment = nil
        for _ in 0..<100 {
            if QLPreviewPanel.shared()?.isVisible != true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        results.append(("closed attachment windows detach their Quick Look source", QLPreviewPanel.shared()?.dataSource == nil))
        // A click previews in Quick Look over the conversation alone: the
        // file actions window used to open beside it.
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true); host.makeKeyAndOrderFront(nil)
        for _ in 0..<100 { if host.isKeyWindow { break }; try await Task.sleep(for: .milliseconds(10)) }
        let hostNext = host.nextResponder
        var previewEnded = false
        var overHost: AttachmentWindow? = AttachmentWindow(attachment: try await client.download(origin.appendingPathComponent("fixture.txt"), to: root), messageLink: nil, presentation: .quickLook(over: host), active: { true }, reportError: { failures.append($0); print("Attachment fixture error: \($0.localizedDescription)"); fflush(nil) })
        overHost?.didClose = { previewEnded = true }
        overHost?.present(save: false)
        results.append(("a preview opens Quick Look over the clicked window without a second window", QLPreviewPanel.shared()?.isVisible == true && (QLPreviewPanel.shared()?.dataSource as AnyObject?) === overHost && overHost?.window?.isVisible == false))
        QLPreviewPanel.shared()?.close()
        for _ in 0..<200 { if previewEnded { break }; try await Task.sleep(for: .milliseconds(10)) }
        results.append(("closing Quick Look ends a preview over a window and restores its responder chain", previewEnded && host.nextResponder === hostNext && QLPreviewPanel.shared()?.dataSource == nil))
        overHost = nil; host.close()
        // A click in the transcript leaves a text view first responder, and
        // NSTextView takes Quick Look ahead of the rest of the chain: every
        // image click opened the file actions window instead of a preview.
        for textView in [LiveResizeTextView(), ComposerView()] as [NSTextView] {
            let focused = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            focused.isReleasedWhenClosed = false
            textView.frame = focused.contentLayoutRect; focused.contentView?.addSubview(textView)
            focused.makeKeyAndOrderFront(nil); focused.makeFirstResponder(textView)
            for _ in 0..<100 { if focused.isKeyWindow { break }; try await Task.sleep(for: .milliseconds(10)) }
            var ended = false
            let fromText = AttachmentWindow(attachment: try await client.download(origin.appendingPathComponent("fixture.txt"), to: root), messageLink: nil, presentation: .quickLook(over: focused), active: { true }, reportError: { failures.append($0); print("Attachment fixture error: \($0.localizedDescription)"); fflush(nil) })
            fromText.didClose = { ended = true }
            fromText.present(save: false)
            results.append(("a preview from a focused \(type(of: textView)) opens Quick Look without a second window", focused.firstResponder === textView && QLPreviewPanel.shared()?.isVisible == true && (QLPreviewPanel.shared()?.dataSource as AnyObject?) === fromText && !fromText.showsOwnWindow))
            QLPreviewPanel.shared()?.close()
            for _ in 0..<200 { if ended { break }; try await Task.sleep(for: .milliseconds(10)) }
            fromText.close(); focused.close()
        }
        // When Quick Look declines the file, the file actions window opens
        // instead. Its responder chain once looped, and the next key press
        // there walked the loop until the app ran out of memory.
        let claimed = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        claimed.isReleasedWhenClosed = false
        let claimant = QuickLookClaimingView(frame: claimed.contentLayoutRect); claimed.contentView?.addSubview(claimant)
        claimed.makeKeyAndOrderFront(nil); claimed.makeFirstResponder(claimant)
        for _ in 0..<100 { if claimed.isKeyWindow { break }; try await Task.sleep(for: .milliseconds(10)) }
        let claimedNext = claimed.nextResponder
        let declined = AttachmentWindow(attachment: try await client.download(origin.appendingPathComponent("fixture.txt"), to: root), messageLink: nil, presentation: .quickLook(over: claimed), active: { true }, reportError: { failures.append($0); print("Attachment fixture error: \($0.localizedDescription)"); fflush(nil) })
        declined.present(save: false)
        results.append(("a preview Quick Look declines opens the file actions with a finite responder chain", declined.showsOwnWindow && declined.window?.isVisible == true && chainEnds(from: declined.window) && claimed.nextResponder === claimedNext))
        results.append(("a preview Quick Look declines still previews from the file actions window", QLPreviewPanel.shared()?.isVisible == true && (QLPreviewPanel.shared()?.dataSource as AnyObject?) === declined))
        // Let Quick Look finish closing first: closing the windows under a
        // closing panel left it open for the checks after this one.
        QLPreviewPanel.shared()?.close()
        for _ in 0..<100 { if QLPreviewPanel.shared()?.isVisible != true { break }; try await Task.sleep(for: .milliseconds(10)) }
        declined.close(); claimed.close()
        results += try await fileInspectorChecks(client: client, origin: origin, root: root)
        results += try await fileDownloadRetryChecks(app: app, client: client, origin: origin, root: root)
        results += try await fileRetryChecks(app: app, origin: origin, root: root)
        let destination = root.appendingPathComponent("exported.txt")
        let completion = Mutex((count: 0, failed: false))
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination, completionHandler: { error in completion.withLock { $0.count += 1; $0.failed = error != nil } })
        let expected = "Nevermore native attachment fixture\n"
        results.append(("outbound file promises retain their file after the preview closes", completion.withLock { $0.count == 1 && !$0.failed } && (try? String(contentsOf: destination, encoding: .utf8)) == expected))
        results.append(("outbound file promises preserve quarantine", (try? destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) != nil))
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination, completionHandler: { error in completion.withLock { $0.count += 1; $0.failed = error != nil } })
        results.append(("outbound file promises refuse to overwrite another file", completion.withLock { $0.count == 2 && $0.failed } && (try? String(contentsOf: destination, encoding: .utf8)) == expected))
        provider.userInfo = nil
        let unsafe = try await client.download(origin.appendingPathComponent("fixture.svg"), to: root)
        let unsafeWindow = AttachmentWindow(attachment: unsafe, messageLink: nil, active: { true }, reportError: { failures.append($0); print("Attachment fixture error: \($0.localizedDescription)"); fflush(nil) })
        unsafeWindow.showWindow(nil)
        unsafeWindow.previewDownloadedFile()
        let preview = unsafeWindow.window?.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSButton.self).first { $0.title == "Quick Look" } }
        results.append(("active attachment formats offer saving without automatic preview", preview?.isEnabled == false && QLPreviewPanel.shared()?.isVisible == false))
        unsafeWindow.close(); await client.invalidate()
        let compressedClient = RavenClient(origin: origin, tokens: nil, clientID: "compressed-fixture", accountID: UUID())
        do {
            let compressed = try await compressedClient.download(origin.appendingPathComponent("compressed.txt"), to: root)
            results.append(("compressed attachment downloads preserve decoded bytes", (try? String(contentsOf: compressed.url, encoding: .utf8)) == expected))
        } catch { print("Compression fixture error: \(error.localizedDescription)"); fflush(nil); results.append(("compressed attachment downloads preserve decoded bytes", false)) }
        await compressedClient.invalidate()
        results.append(("native attachment fixture completed", failures.isEmpty))
        return results
    }

    /// The File panel a click opens: a live preview of passive files, the
    /// file's details, and actions that reach the window that hosts it.
    private static func fileInspectorChecks(client: RavenClient, origin: URL, root: URL) async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        func panel(_ filename: String, active: @escaping () -> Bool = { true }, savePanel: @escaping @MainActor () -> NSSavePanel = { NSSavePanel() }) -> FileInspector {
            let source = FileInspectorSource(messageID: "file-message", channelID: "file-channel", filename: filename, sender: "Fixture Sender", sent: "09:42", conversation: "#fixtures", messageLink: URL(string: "https://example.invalid/raven/message/file-message"))
            let inspector = FileInspector(source: source, active: active, reportError: { print("File panel fixture error: \($0.localizedDescription)"); fflush(nil) }, makeSavePanel: savePanel)
            inspector.view.frame = host.contentLayoutRect; host.contentView = inspector.view
            inspector.start(); host.layoutIfNeeded()
            return inspector
        }
        func texts(_ inspector: FileInspector) -> [String] { InteractionSelfChecks.descendants(inspector.view, of: NSTextField.self).filter { !$0.isHidden }.map(\.stringValue) }
        func button(_ inspector: FileInspector, _ title: String) -> NSButton? { InteractionSelfChecks.descendants(inspector.view, of: NSButton.self).first { $0.title == title } }

        let image = panel("fixture.png")
        results.append(("the File panel shows the message's details and waits for its file", texts(image).contains("Downloading…") && texts(image).contains("Fixture Sender") && texts(image).contains("#fixtures") && button(image, "Quick Look")?.isEnabled == false))
        let png = try await client.download(origin.appendingPathComponent("fixture.png"), to: root)
        image.show(png)
        results.append(("the File panel previews a downloaded image inline", ((image.previewView?.previewItem as? NSURL) as URL?) == png.url && image.previewView?.superview != nil))
        results.append(("the File panel lists an image's size and dimensions", texts(image).contains("30 × 20 pixels") && texts(image).contains(ByteCountFormatter.string(fromByteCount: Int64(png.byteCount), countStyle: .file))))
        var quickLooked: DownloadedAttachment?
        image.onQuickLook = { quickLooked = $0 }
        button(image, "Quick Look")?.performClick(nil)
        results.append(("Quick Look in the File panel shows the panel's own download", quickLooked === png))
        var shown: String?
        image.onShowMessage = { shown = $0 }
        button(image, "Show Message")?.performClick(nil)
        results.append(("Show Message in the File panel finds the file's message", shown == "file-message"))
        let preview = image.previewView
        image.detach()
        results.append(("closing the File panel ends its preview and releases the file", image.attachment == nil && image.previewView == nil && preview?.superview == nil && button(image, "Save As…")?.isEnabled == false))
        quickLooked = nil

        let svg = try await client.download(origin.appendingPathComponent("fixture.svg"), to: root)
        var savePanels: [RecordingSavePanel] = []
        let active = panel("fixture.svg", savePanel: { let panel = RecordingSavePanel(); savePanels.append(panel); return panel })
        active.show(svg)
        active.onQuickLook = { quickLooked = $0 }
        active.showQuickLook()
        results.append(("the File panel never renders an active format, but offers to save it", active.previewView == nil && button(active, "Quick Look")?.isEnabled == false && button(active, "Save As…")?.isEnabled == true && quickLooked == nil))
        _ = await active.saveCopy()
        let blocker = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        blocker.isReleasedWhenClosed = false
        host.beginSheet(blocker) { _ in }
        let blocked = host.attachedSheet === blocker
        _ = await active.saveCopy()
        host.endSheet(blocker); blocker.close()
        results.append(("Save As asks on a sheet, or in its own window while another sheet is open", blocked && savePanels.map(\.presentedAsSheet) == [true, false]))
        active.detach()

        // Save As for a search result goes straight to the save sheet.
        let reader = SearchAttachmentReader()
        var searchPanels: [RecordingSavePanel] = []
        reader.makeSavePanel = { let panel = RecordingSavePanel(); searchPanels.append(panel); return panel }
        reader.deliver(svg, link: nil, save: true, over: host, live: { true }, reportError: { print("Search save fixture error: \($0.localizedDescription)"); fflush(nil) })
        for _ in 0..<100 where searchPanels.first?.presentedAsSheet == nil { await Task.yield() }
        results.append(("Save As for a search result asks on a sheet, with no file actions window", searchPanels.map(\.presentedAsSheet) == [true] && reader.windows.isEmpty))
        reader.cancel()

        var allowed = true
        let revoked = panel("fixture.txt", active: { allowed })
        var closedByAccess = false
        revoked.onClose = { closedByAccess = true }
        revoked.show(try await client.download(origin.appendingPathComponent("fixture.txt"), to: root))
        allowed = false
        NotificationCenter.default.post(name: .sessionChanged, object: nil)
        for _ in 0..<100 { if closedByAccess { break }; try await Task.sleep(for: .milliseconds(10)) }
        results.append(("the File panel closes when its conversation is no longer accessible", closedByAccess))
        revoked.detach()
        return results
    }

    /// Each file fails on its first GET. Exercise all three retry entry
    /// points and inspect the request counts after the downloads settle.
    private static func fileDownloadRetryChecks(app: AppDelegate, client: RavenClient, origin: URL, root: URL) async throws -> [(String, Bool)] {
        let account = Account(origin: origin, user: "file-fixture", siteName: "Local fixture", clientID: "local-fixture")
        let session = try AccountSession(account: account, directory: root)
        let channel = RavenChannel(raw: .object(["name": .string("file-retry"), "channel_name": .string("Files")]))
        session.channels = [channel]
        let owner = ConversationWindow(app: app, session: session)
        owner.channel = channel
        owner.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 760), display: false)
        defer { owner.close(); session.stop() }

        var saves: [RecordingSavePanel] = []
        owner.makeFileInspectorSavePanel = { let panel = RecordingSavePanel(); saves.append(panel); return panel }
        var checks: [(String, Bool)] = []
        for id in ["retry-button", "retry-click", "retry-save"] {
            let message = RavenMessage(raw: .object(["name": .string(id), "channel_id": .string(channel.id), "message_type": .string("File"), "file": .string("/" + id + ".txt")]))
            owner.showFileInspector(for: message)
            await owner.fileDownload?.value
            guard let inspector = owner.fileInspector,
                  let button = InteractionSelfChecks.descendants(inspector.view, of: NSButton.self).first(where: { $0.title == "Try Again" }),
                  !button.isHiddenOrHasHiddenAncestor else {
                checks.append(("a failed download exposes Try Again for " + id, false))
                continue
            }
            switch id {
            case "retry-button":
                session.revokedChannels.insert(channel.id)
                button.performClick(nil)
                checks.append(("a retry refuses a revoked conversation", owner.fileDownload == nil))
                session.revokedChannels.remove(channel.id)
                button.performClick(nil)
            case "retry-save": owner.fetchAttachment(save: true, message: message)
            default: owner.previewAttachment(for: message)
            }
            // A second click while the retry is in flight joins it.
            owner.showFileInspector(for: message)
            await owner.fileDownload?.value
            if id == "retry-save" {
                for _ in 0..<100 where saves.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            }
            checks.append((id + " restores the same File panel", owner.fileInspector === inspector && inspector.attachment != nil))
            checks.append((id + " preserves the explicit save choice", saves.count == (id == "retry-save" ? 1 : 0)))
        }
        let counts = try await client.rpc("nevermore_fixture.retry_counts")
        checks.append(("each failed file downloads exactly once more",
                       ["/retry-button.txt", "/retry-click.txt", "/retry-save.txt"].allSatisfy { counts[$0] == .number(2) }))
        return checks
    }

    /// A failed download offers one retry; activating the same message again
    /// while it runs joins that single attempt and keeps the same panel.
    private static func fileRetryChecks(app: AppDelegate, origin: URL, root: URL) async throws -> [(String, Bool)] {
        let account = Account(origin: origin, user: "retry-fixture", siteName: "Fixture", clientID: "local-fixture")
        let session = try AccountSession(account: account, directory: root.appendingPathComponent("retry-account"), demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("retry-channel")]))
        let message = RavenMessage(raw: .object(["name": .string("retry-message"), "channel_id": .string(channel.id),
                                                  "file": .string("/retry-attachment.txt"), "message_type": .string("File")]))
        let owner = ConversationWindow(app: app, session: session)
        defer { owner.close(); session.stop() }
        session.channels = [channel]
        owner.select(channel)
        owner.showFileInspector(for: message)
        await owner.fileDownload?.value
        guard let panel = owner.fileInspector else { return [("failed File panel remains open", false)] }
        let retry = InteractionSelfChecks.descendants(panel.view, of: NSButton.self).first { $0.title == "Try Again" }
        let offered = retry?.isHidden == false && retry?.isEnabled == true && panel.attachment == nil
        retry?.performClick(nil)
        let attempt = owner.fileDownload
        owner.showFileInspector(for: message)
        let singleAttempt = attempt != nil && owner.fileDownload == attempt
        await attempt?.value
        return [
            ("a failed File panel offers Retry without replacing its details", offered),
            ("Retry and a repeated click share one download and recover in the same File panel",
             singleAttempt && owner.fileInspector === panel && panel.attachment?.filename == "retry-attachment.txt"),
        ]
    }

    /// Whether a responder chain reaches its end instead of looping.
    private static func chainEnds(from start: NSResponder?) -> Bool {
        var seen = Set<ObjectIdentifier>(), responder = start
        while let current = responder {
            guard seen.insert(ObjectIdentifier(current)).inserted else { return false }
            responder = current.nextResponder
        }
        return true
    }
}

/// Records how the File panel presents Save As and cancels at once, so the
/// check never shows a real save panel.
private final class RecordingSavePanel: NSSavePanel {
    private(set) var presentedAsSheet: Bool?
    override func beginSheetModal(for window: NSWindow, completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) { presentedAsSheet = true; handler(.cancel) }
    override func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) { presentedAsSheet = false; handler(.cancel) }
}

/// Takes Quick Look before any responder after it in its window, so a
/// preview over that window falls back to the file actions window.
private final class QuickLookClaimingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {}
    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
