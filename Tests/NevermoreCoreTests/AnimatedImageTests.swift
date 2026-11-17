import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NevermoreCore

final class AnimatedImageTests: XCTestCase {
    /// An animated GIF of `delays.count` solid frames.
    static func gif(width: Int = 40, height: Int = 20, delays: [Double]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, delays.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, delay) in delays.enumerated() {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(index % 2), green: 0.5, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testDecodesEveryFrameWithItsDelay() throws {
        let image = try XCTUnwrap(AnimatedImageDecoder.decode(Self.gif(delays: [0.1, 0.2, 0.3]), maxPixelSide: 400))
        XCTAssertEqual(image.frames.count, 3)
        XCTAssertTrue(image.isAnimated)
        XCTAssertEqual(image.delays, [0.1, 0.2, 0.3], accuracy: 0.001)
        XCTAssertEqual(image.duration, 0.6, accuracy: 0.001)
        XCTAssertEqual(image.keyTimes, [0, 1.0 / 6, 0.5], accuracy: 0.001)
        XCTAssertEqual(image.sourcePixelSize, CGSize(width: 40, height: 20))
        // Never enlarged beyond the source.
        XCTAssertEqual(image.frames[0].width, 40)
    }

    func testScalesDownToTheRequestedSide() throws {
        let image = try XCTUnwrap(AnimatedImageDecoder.decode(Self.gif(width: 200, height: 100, delays: [0.1, 0.1]), maxPixelSide: 50))
        XCTAssertEqual(max(image.frames[0].width, image.frames[0].height), 50)
    }

    func testTinyAndZeroDelaysPlayLikeBrowsers() {
        XCTAssertEqual(AnimatedImageDecoder.normalizedDelay(0), 0.1)
        XCTAssertEqual(AnimatedImageDecoder.normalizedDelay(0.01), 0.1)
        XCTAssertEqual(AnimatedImageDecoder.normalizedDelay(nil), 0.1)
        XCTAssertEqual(AnimatedImageDecoder.normalizedDelay(.nan), 0.1)
        XCTAssertEqual(AnimatedImageDecoder.normalizedDelay(0.04), 0.04)
        XCTAssertEqual(AnimatedImageDecoder.normalizedDelay(600), 60)
    }

    func testStillImageIsOneFrame() throws {
        let image = try XCTUnwrap(AnimatedImageDecoder.decode(Self.gif(delays: [0.5]), maxPixelSide: 100))
        XCTAssertEqual(image.frames.count, 1)
        XCTAssertFalse(image.isAnimated)
    }

    func testRejectsNonImagesAndOversizedInput() {
        XCTAssertNil(AnimatedImageDecoder.decode(Data("<html></html>".utf8), maxPixelSide: 100))
        XCTAssertNil(AnimatedImageDecoder.decode(Data(), maxPixelSide: 100))
        let gif = Self.gif(delays: [0.1, 0.1])
        var small = AnimatedImageDecoder.Limits.standard
        small.encodedBytes = gif.count - 1
        XCTAssertNil(AnimatedImageDecoder.decode(gif, maxPixelSide: 100, limits: small))
        var narrow = AnimatedImageDecoder.Limits.standard
        narrow.sourceSide = 39
        XCTAssertNil(AnimatedImageDecoder.decode(gif, maxPixelSide: 100, limits: narrow))
        var few = AnimatedImageDecoder.Limits.standard
        few.frames = 1
        XCTAssertNil(AnimatedImageDecoder.decode(gif, maxPixelSide: 100, limits: few))
    }

    func testStaysWithinTheDecodedBudget() throws {
        var limits = AnimatedImageDecoder.Limits.standard
        // Room for about four 40 x 20 frames.
        limits.decodedBytes = 40 * 20 * 4 * 4
        limits.minimumSide = 40
        let image = try XCTUnwrap(AnimatedImageDecoder.decode(Self.gif(delays: Array(repeating: 0.1, count: 10)), maxPixelSide: 400, limits: limits))
        XCTAssertLessThanOrEqual(image.decodedBytes, limits.decodedBytes + image.frames[0].bytesPerRow * image.frames[0].height)
        XCTAssertLessThan(image.frames.count, 10)
        // Dropped frames keep their time: the loop lasts as long as before.
        XCTAssertEqual(image.duration, 1.0, accuracy: 0.001)
    }

    func testPlanShrinksBeforeDroppingFrames() {
        var limits = AnimatedImageDecoder.Limits.standard
        limits.decodedBytes = 100 * 100 * 4 * 10
        limits.minimumSide = 50
        // 20 frames of 200 x 200 would need 4x the budget at 100 px; halving the side is enough.
        let plan = AnimatedImageDecoder.plan(width: 200, height: 200, frames: 20, maxPixelSide: 100, limits: limits)
        XCTAssertEqual(plan.stride, 1)
        XCTAssertLessThanOrEqual(plan.side, 71)
        XCTAssertGreaterThanOrEqual(plan.side, 50)
        // 400 frames cannot fit even at the minimum side, so frames go.
        let long = AnimatedImageDecoder.plan(width: 200, height: 200, frames: 400, maxPixelSide: 100, limits: limits)
        XCTAssertEqual(long.side, 50)
        XCTAssertGreaterThan(long.stride, 1)
    }

    func testPlanNeverAsksForAZeroSide() {
        var limits = AnimatedImageDecoder.Limits.standard
        limits.decodedBytes = 4
        limits.minimumSide = 0
        // ImageIO reads a zero maximum side as no limit at all.
        XCTAssertEqual(AnimatedImageDecoder.plan(width: 4000, height: 4000, frames: 100, maxPixelSide: 4000, limits: limits).side, 1)
    }

    /// `gifsicle -O3` output: over a red 40 x 40 first frame, the second
    /// frame stores only a 10 x 10 blue patch and the third a green one.
    func testOptimizedGIFFramesAreComposited() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "R0lGODlhKAAoAPEAAAD5AAQz//8mAAAAACH5BAUKAAAALAAAAAAoACgAAAInlI+py+0Po5y02ouz3rz7D4biSJbmiabqyrbuC8fyTNf2jef6ziMFACH5BAUKAAAALAUAGQAKAAoAAAIIjI+py+0PYysAIfkEBQoAAQAsGQAFAAoACgAAAgiEj6nL7Q9jKwA7"))
        let image = try XCTUnwrap(AnimatedImageDecoder.decode(data, maxPixelSide: 40))
        XCTAssertEqual(image.frames.count, 3)
        let last = image.frames[2]
        XCTAssertEqual([last.width, last.height], [40, 40])
        // Both patches show on the last frame, over the first frame's red.
        XCTAssertEqual(Self.dominant(last, x: 10, y: 30), "blue")
        XCTAssertEqual(Self.dominant(last, x: 30, y: 10), "green")
        XCTAssertEqual(Self.dominant(last, x: 1, y: 1), "red")
    }

    /// The strongest channel of the pixel at `x`, `y` from the top left.
    private static func dominant(_ image: CGImage, x: Int, y: Int) -> String {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        let channels = ["red": pixel[0], "green": pixel[1], "blue": pixel[2]]
        return channels.max { $0.value < $1.value }!.key
    }
}

private func XCTAssertEqual(_ lhs: [Double], _ rhs: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (a, b) in zip(lhs, rhs) { XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line) }
}
