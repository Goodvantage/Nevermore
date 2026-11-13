import AppKit

@MainActor enum ClipboardAttachmentSelfChecks {
    static func run() -> [(String, Bool)] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Nevermore-clipboard-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let composer = ComposerView()
        composer.string = "keep this draft"
        var images: [String] = [], files: [URL] = [], error = ""
        composer.onImage = { _, ext in images.append(ext) }
        composer.onFiles = { files = $0 }
        composer.onPasteError = { error = $0 }
        var results: [(String, Bool)] = []
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            pasteboard.clearContents(); pasteboard.setData(Data([1, 2, 3]), forType: type)
            results.append(("\(ext) clipboard images use attachment staging", composer.pasteAttachments(from: pasteboard) && images.last == ext && composer.string == "keep this draft"))
        }
        let file = URL(fileURLWithPath: "/tmp/Nevermore-paste-fixture.png")
        pasteboard.clearContents(); pasteboard.writeObjects([file as NSURL])
        results.append(("clipboard file URLs use attachment staging", composer.pasteAttachments(from: pasteboard) && files == [file]))
        pasteboard.clearContents(); pasteboard.setData(Data(count: ComposerView.clipboardImageLimit + 1), forType: .png)
        error = ""
        results.append(("oversized clipboard images show the limit without changing text", composer.pasteAttachments(from: pasteboard) && error.contains("20 MB") && composer.string == "keep this draft"))
        composer.onAttachmentRequest = { error = ComposerView.editingAttachmentMessage; return false }
        pasteboard.clearContents(); pasteboard.setData(Data([1]), forType: .png)
        let imageCount = images.count
        results.append(("editing rejects attachments with an explanation", composer.pasteAttachments(from: pasteboard) && images.count == imageCount && error.contains("Send a new message")))
        composer.onAttachmentRequest = nil; error = ""
        pasteboard.clearContents(); pasteboard.declareTypes([.init("com.apple.pasteboard.promised-file-content-type"), .init("com.apple.pasteboard.promised-file-url")], owner: nil)
        results.append(("unavailable promised files show an error", composer.pasteAttachments(from: pasteboard) && !error.isEmpty))
        return results
    }
}
