import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NevermoreCore

@Suite struct AttachmentDetailsTests {
    @Test func kindNamesTheExtensionBeforeTheServerType() {
        #expect(AttachmentDetails.kind(filename: "photo.jpg", mimeType: "application/pdf") == UTType.jpeg.localizedDescription)
        #expect(AttachmentDetails.kind(filename: "report", mimeType: "application/pdf; charset=binary") == UTType.pdf.localizedDescription)
        #expect(AttachmentDetails.kind(filename: "PHOTO.JPG", mimeType: nil) == UTType.jpeg.localizedDescription)
        #expect(AttachmentDetails.kind(filename: "notes.txt", mimeType: "image/png") == UTType.plainText.localizedDescription)
        #expect(AttachmentDetails.kind(filename: "blob", mimeType: nil) == "Document")
    }

    @Test func pixelSizeReadsTheHeaderAndHonoursRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDetailsTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upright = directory.appendingPathComponent("upright.png"), turned = directory.appendingPathComponent("turned.jpg")
        try writeImage(to: upright, type: .png, width: 30, height: 20, orientation: nil)
        try writeImage(to: turned, type: .jpeg, width: 30, height: 20, orientation: 6)
        #expect(AttachmentDetails.pixelSize(ofImageAt: upright).map { [$0.width, $0.height] } == [30, 20])
        #expect(AttachmentDetails.pixelSize(ofImageAt: turned).map { [$0.width, $0.height] } == [20, 30])
        let text = directory.appendingPathComponent("notes.txt"); try Data("not an image".utf8).write(to: text)
        #expect(AttachmentDetails.pixelSize(ofImageAt: text) == nil)
        #expect(AttachmentDetails.dimensionsText(width: 20, height: 30) == "20 × 30 pixels")
    }

    private func writeImage(to url: URL, type: UTType, width: Int, height: Int, orientation: Int?) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
    }
}
