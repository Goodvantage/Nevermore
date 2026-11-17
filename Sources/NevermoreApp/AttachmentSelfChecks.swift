import AppKit
import QuickLookUI
import RavenProtocol
import Synchronization

@MainActor enum AttachmentSelfChecks {
    static func run(origin input: String) async throws -> [(String, Bool)] {
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
        QLPreviewPanel.shared()?.close(); declined.close(); claimed.close()
        for _ in 0..<100 { if QLPreviewPanel.shared()?.isVisible != true { break }; try await Task.sleep(for: .milliseconds(10)) }
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

/// Takes Quick Look before any responder after it in its window, so a
/// preview over that window falls back to the file actions window.
private final class QuickLookClaimingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {}
    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
