import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The facts the File panel lists about a downloaded attachment.
public enum AttachmentDetails {
    /// A readable file kind, such as "JPEG image", from the name's extension.
    /// The server's MIME type is the fallback; it is untrusted and only named.
    public static func kind(filename: String, mimeType: String?) -> String {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription { return description }
        let mime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if !mime.isEmpty, let type = UTType(mimeType: mime), let description = type.localizedDescription { return description }
        return "Document"
    }

    /// The width and height an image shows at, in pixels, read from its
    /// header without decoding it. EXIF orientations 5 to 8 turn the stored
    /// image a quarter turn, so they swap the stored width and height.
    public static func pixelSize(ofImageAt url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    public static func dimensionsText(width: Int, height: Int) -> String { "\(width) × \(height) pixels" }
}
