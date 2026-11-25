import XCTest
import RavenProtocol
import UniformTypeIdentifiers
@testable import NevermoreCore

final class TranscriptMediaLayoutTests: XCTestCase {
    func testLandscapeBannersGoUnderTheText() {
        // A standard og:image banner (1200 x 630).
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 1200, pixelHeight: 630, thumbnailHeight: 72), .banner(heightRatio: 630.0 / 1200.0))
        // Raven's web client draws the line at 400 pixels and a 1.4 ratio.
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 400, pixelHeight: 280, thumbnailHeight: 72), .banner(heightRatio: 0.7))
    }

    func testOtherPicturesSitBesideTheText() {
        // Logos and avatars are square: Forgejo's preview picture is one.
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 512, pixelHeight: 512, thumbnailHeight: 72), .thumbnail(CGSize(width: 72, height: 72)))
        // Wide but small, or large but not wide enough, stays a thumbnail.
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 399, pixelHeight: 200, thumbnailHeight: 72), .thumbnail(CGSize(width: 115, height: 72)))
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 1300, pixelHeight: 1000, thumbnailHeight: 72), .thumbnail(CGSize(width: 94, height: 72)))
        // Slivers are cropped to a bounded shape.
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 100, pixelHeight: 900, thumbnailHeight: 72), .thumbnail(CGSize(width: 54, height: 72)))
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 390, pixelHeight: 50, thumbnailHeight: 72), .thumbnail(CGSize(width: 115, height: 72)))
    }

    func testUnknownSizesGetASquareThumbnail() {
        let square = TranscriptMediaLayout.PreviewPicture.thumbnail(CGSize(width: 72, height: 72))
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: nil, pixelHeight: nil, thumbnailHeight: 72), square)
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 1200, pixelHeight: nil, thumbnailHeight: 72), square)
        XCTAssertEqual(TranscriptMediaLayout.previewPicture(pixelWidth: 0, pixelHeight: 630, thumbnailHeight: 72), square)
    }

    func testBannersFillTheCardUpToAHeight() {
        XCTAssertEqual(TranscriptMediaLayout.bannerSize(heightRatio: 0.525, width: 488, maximumHeight: 280), CGSize(width: 488, height: 256))
        // Too tall at full width: as tall as allowed, narrower, same shape.
        XCTAssertEqual(TranscriptMediaLayout.bannerSize(heightRatio: 0.7, width: 488, maximumHeight: 280), CGSize(width: 400, height: 280))
        XCTAssertEqual(TranscriptMediaLayout.bannerSize(heightRatio: 0, width: 488, maximumHeight: 280), .zero)
    }

    func testFittingNeverEnlarges() {
        XCTAssertEqual(TranscriptMediaLayout.fit(CGSize(width: 480, height: 320), maximumSide: 320), CGSize(width: 320, height: 213))
        XCTAssertEqual(TranscriptMediaLayout.fit(CGSize(width: 240, height: 480), maximumSide: 320), CGSize(width: 160, height: 320))
        XCTAssertEqual(TranscriptMediaLayout.fit(CGSize(width: 100, height: 80), maximumSide: 320), CGSize(width: 100, height: 80))
        XCTAssertEqual(TranscriptMediaLayout.fit(CGSize(width: 4000, height: 1), maximumSide: 320), CGSize(width: 320, height: 1))
        XCTAssertEqual(TranscriptMediaLayout.fit(.zero, maximumSide: 320), .zero)
    }

    func testPicturesDecodeJustLargeEnoughToCoverTheirBox() {
        // A standard banner across a 488-point card on a Retina display.
        XCTAssertEqual(TranscriptMediaLayout.coveringPixels(pixelWidth: 1200, pixelHeight: 630, box: CGSize(width: 488, height: 256), scale: 2), 976)
        // A square logo in a 72-point thumbnail.
        XCTAssertEqual(TranscriptMediaLayout.coveringPixels(pixelWidth: 512, pixelHeight: 512, box: CGSize(width: 72, height: 72), scale: 2), 144)
        // Cropped to fill: a wide picture keeps the box's full height.
        XCTAssertEqual(TranscriptMediaLayout.coveringPixels(pixelWidth: 1200, pixelHeight: 600, box: CGSize(width: 72, height: 72), scale: 2), 288)
        // Never enlarged.
        XCTAssertEqual(TranscriptMediaLayout.coveringPixels(pixelWidth: 100, pixelHeight: 80, box: CGSize(width: 115, height: 72), scale: 2), 100)
        XCTAssertEqual(TranscriptMediaLayout.coveringPixels(pixelWidth: 0, pixelHeight: 80, box: CGSize(width: 72, height: 72), scale: 2), 0)
    }

    func testStoredImageSizesComeFromRavensThumbnailFields() {
        func message(_ fields: [String: JSONValue]) -> RavenMessage {
            RavenMessage(raw: .object(["name": .string("m"), "message_type": .string("Image")].merging(fields) { _, new in new }))
        }
        XCTAssertEqual(TranscriptMediaLayout.storedImageSize(message(["thumbnail_width": .number(480), "thumbnail_height": .number(320)]), maximumSide: 320), CGSize(width: 320, height: 213))
        // Data fields may arrive as text.
        XCTAssertEqual(TranscriptMediaLayout.storedImageSize(message(["thumbnail_width": .string("240"), "thumbnail_height": .string("480")]), maximumSide: 320), CGSize(width: 160, height: 320))
        XCTAssertNil(TranscriptMediaLayout.storedImageSize(message([:]), maximumSide: 320))
        XCTAssertNil(TranscriptMediaLayout.storedImageSize(message(["thumbnail_width": .string(""), "thumbnail_height": .number(320)]), maximumSide: 320))
        XCTAssertNil(TranscriptMediaLayout.storedImageSize(message(["thumbnail_width": .number(-4), "thumbnail_height": .number(320)]), maximumSide: 320))
        XCTAssertNil(TranscriptMediaLayout.storedImageSize(message(["thumbnail_width": .number(1e9), "thumbnail_height": .number(320)]), maximumSide: 320))
    }

    func testPictureBoxesStayPutWhenThePictureLoads() {
        let fallback = CGSize(width: 240, height: 180)
        let stored = CGSize(width: 320, height: 213)
        // Before it loads: the box it had, then the stored size, then the fallback.
        XCTAssertEqual(TranscriptMediaLayout.pictureBox(loaded: nil, stored: stored, remembered: nil, fallback: fallback), stored)
        XCTAssertEqual(TranscriptMediaLayout.pictureBox(loaded: nil, stored: stored, remembered: CGSize(width: 213, height: 320), fallback: fallback), CGSize(width: 213, height: 320))
        XCTAssertEqual(TranscriptMediaLayout.pictureBox(loaded: nil, stored: nil, remembered: nil, fallback: fallback), fallback)
        // Loaded at the stored shape, give or take rounding: the stored box stays.
        XCTAssertEqual(TranscriptMediaLayout.pictureBox(loaded: CGSize(width: 320, height: 214), stored: stored, remembered: nil, fallback: fallback), stored)
        // A different shape (a rotated photo) takes the picture's own size.
        XCTAssertEqual(TranscriptMediaLayout.pictureBox(loaded: CGSize(width: 213, height: 320), stored: stored, remembered: nil, fallback: fallback), CGSize(width: 213, height: 320))
        XCTAssertEqual(TranscriptMediaLayout.pictureBox(loaded: CGSize(width: 100, height: 80), stored: nil, remembered: nil, fallback: fallback), CGSize(width: 100, height: 80))
    }

    func testFileSummaryNamesTheKindAndSize() {
        let pdf = UTType.pdf.localizedDescription ?? ""
        XCTAssertEqual(AttachmentDetails.summary(filename: "report.pdf", byteCount: 2_400_000), "\(pdf) · \(ByteCountFormatter.string(fromByteCount: 2_400_000, countStyle: .file))")
        XCTAssertEqual(AttachmentDetails.summary(filename: "report.pdf", byteCount: nil), pdf)
        XCTAssertEqual(AttachmentDetails.summary(filename: "report.pdf", byteCount: 0), pdf)
        XCTAssertEqual(AttachmentDetails.summary(filename: "no-extension", byteCount: nil), "Document")
    }
}
