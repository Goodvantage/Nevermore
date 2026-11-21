import AppKit
import RavenProtocol

/// Saving a user-owned copy of a private download. Other apps only ever
/// receive such a copy, never the private cache file.
@MainActor enum AttachmentExport {
    /// Asks where to save on a sheet over `window`, then writes a quarantined
    /// copy there. Nil when the user cancels or `isCurrent` turns false while
    /// the sheet or the copy is under way. When `window` already shows a
    /// sheet, such as an alert, the panel opens as its own window instead, so
    /// the request is never dropped.
    static func saveCopy(of attachment: DownloadedAttachment, using panel: NSSavePanel, over window: NSWindow, isCurrent: () -> Bool) async throws -> URL? {
        panel.nameFieldStringValue = attachment.filename
        let response = await withCheckedContinuation { continuation in
            if window.attachedSheet == nil { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            else { panel.begin { continuation.resume(returning: $0) } }
        }
        guard response == .OK, let target = panel.url, isCurrent() else { return nil }
        try await Task.detached(priority: .userInitiated) { try attachment.export(to: target, replacing: true) }.value
        return isCurrent() ? target : nil
    }

    /// Menu items for the apps that open a saved copy, each carrying its app URL.
    static func openWithItems(for savedURL: URL) -> [NSMenuItem] {
        NSWorkspace.shared.urlsForApplications(toOpen: savedURL).map { app in
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: nil, keyEquivalent: "")
            item.representedObject = app
            return item
        }
    }
}
