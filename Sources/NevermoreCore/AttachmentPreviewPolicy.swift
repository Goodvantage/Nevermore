import Foundation

public enum AttachmentPreviewKind: Sendable, Equatable { case image, pdf, audio, video, text, unsupported }

/// A conservative preview selector, not a malware scanner. Unsupported files
/// can still be saved explicitly with quarantine; they are never auto-opened.
public enum AttachmentPreviewPolicy {
    private static let denied: Set<String> = ["app", "exe", "dll", "dylib", "pkg", "dmg", "command", "sh", "bash", "zsh", "bat", "cmd", "ps1", "py", "js", "jse", "vbs", "scpt", "applescript", "workflow", "html", "htm", "svg", "webloc", "url", "shortcut"]
    public static func kind(filename: String, mimeType: String?) -> AttachmentPreviewKind {
        guard !filename.isEmpty, !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !filename.contains("/"), !filename.contains("\\") else { return .unsupported }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !denied.contains(ext) else { return .unsupported }
        let category: AttachmentPreviewKind
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic", "heif", "bmp": category = .image
        case "pdf": category = .pdf
        case "mp3", "m4a", "aac", "wav", "flac", "ogg": category = .audio
        case "mp4", "mov", "m4v", "webm": category = .video
        case "txt", "md", "log", "json", "csv", "yaml", "yml", "xml": category = .text
        default: return .unsupported
        }
        let mime = mimeType?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
        if mime.isEmpty || mime == "application/octet-stream" { return category }
        switch category {
        case .image: return mime.hasPrefix("image/") && mime != "image/svg+xml" ? .image : .unsupported
        case .pdf: return mime == "application/pdf" ? .pdf : .unsupported
        case .audio: return mime.hasPrefix("audio/") ? .audio : .unsupported
        case .video: return mime.hasPrefix("video/") ? .video : .unsupported
        case .text: return ["text/plain", "text/csv", "text/markdown", "application/json", "application/xml", "text/xml", "application/yaml", "text/yaml"].contains(mime) ? .text : .unsupported
        case .unsupported: return .unsupported
        }
    }
}
