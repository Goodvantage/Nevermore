import Testing
@testable import NevermoreCore

@Suite struct AttachmentPreviewPolicyTests {
    @Test func knownPassiveTypesAcceptMissingOrGenericMetadata() {
        #expect(AttachmentPreviewPolicy.kind(filename: "photo.PNG", mimeType: nil) == .image)
        #expect(AttachmentPreviewPolicy.kind(filename: "report.pdf", mimeType: "application/octet-stream") == .pdf)
        #expect(AttachmentPreviewPolicy.kind(filename: "sound.mp3", mimeType: "audio/mpeg") == .audio)
        #expect(AttachmentPreviewPolicy.kind(filename: "movie.mov", mimeType: "video/quicktime") == .video)
        #expect(AttachmentPreviewPolicy.kind(filename: "data.json", mimeType: "application/json") == .text)
        #expect(AttachmentPreviewPolicy.kind(filename: "notes.md", mimeType: " TEXT/MARKDOWN ; charset=utf-8") == .text)
    }
    @Test func activeContentAndDisguisedExecutablesAreNeverPreviewed() {
        for ext in ["app", "exe", "command", "sh", "py", "js", "html", "svg", "webloc", "url", "scpt", "dmg", "pkg"] {
            #expect(AttachmentPreviewPolicy.kind(filename: "payload.\(ext)", mimeType: "image/png") == .unsupported)
        }
        #expect(AttachmentPreviewPolicy.kind(filename: "photo.png", mimeType: "text/html") == .unsupported)
        #expect(AttachmentPreviewPolicy.kind(filename: "photo.png", mimeType: "image/svg+xml") == .unsupported)
        #expect(AttachmentPreviewPolicy.kind(filename: "report.pdf", mimeType: "application/javascript") == .unsupported)
        #expect(AttachmentPreviewPolicy.kind(filename: "data.txt", mimeType: "text/html") == .unsupported)
    }
    @Test func unknownTypesAndPathsDoNotGainPreviewPermissionFromMIME() {
        #expect(AttachmentPreviewPolicy.kind(filename: "unknown.bin", mimeType: "application/pdf") == .unsupported)
        #expect(AttachmentPreviewPolicy.kind(filename: "photo", mimeType: "image/png") == .unsupported)
        for name in ["../photo.png", "folder\\photo.png", "bad\nname.png", "bad\0name.txt", ""] {
            #expect(AttachmentPreviewPolicy.kind(filename: name, mimeType: nil) == .unsupported)
        }
    }
}
