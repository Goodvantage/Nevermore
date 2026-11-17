import CoreGraphics
import Foundation
import ImageIO

/// The frames of an animated image, decoded once at display size so the
/// transcript can hand them to Core Animation instead of decoding a frame
/// on the main thread at every tick.
///
/// Decoded frames are uncompressed, so the decoder trades sharpness for a
/// fixed memory ceiling: a long GIF is decoded smaller, and an extremely
/// long one keeps every n-th frame (with its delay folded into the frame
/// before it) rather than exceeding `Limits.decodedBytes`. An image with
/// more than `Limits.frames` frames is not decoded at all.
public struct AnimatedImage: Sendable {
    public let frames: [CGImage]
    /// Seconds each frame stays on screen, one per frame.
    public let delays: [TimeInterval]
    /// Pixel size of the source's first frame, before scaling.
    public let sourcePixelSize: CGSize

    public var isAnimated: Bool { frames.count > 1 }
    public var duration: TimeInterval { delays.reduce(0, +) }
    public var decodedBytes: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    /// Start of each frame as a fraction of `duration`, for a discrete
    /// `CAKeyframeAnimation`. Core Animation wants one more key time than
    /// values for discrete mode; callers append 1 themselves when needed.
    public var keyTimes: [Double] {
        let total = duration
        guard total > 0 else { return frames.indices.map { _ in 0 } }
        var elapsed: TimeInterval = 0
        return delays.map { delay in
            defer { elapsed += delay }
            return elapsed / total
        }
    }
}

public enum AnimatedImageDecoder {
    public struct Limits: Sendable {
        /// Compressed input accepted at all.
        public var encodedBytes: Int
        /// Largest side the source may declare, in pixels.
        public var sourceSide: Int
        /// Largest area the source may declare, in pixels.
        public var sourceArea: Int
        public var frames: Int
        /// Ceiling for all decoded frames of one image together.
        public var decodedBytes: Int
        /// Frames are never scaled below this largest side; frames are
        /// dropped instead.
        public var minimumSide: Int

        public init(encodedBytes: Int = 16 * 1024 * 1024, sourceSide: Int = 4096, sourceArea: Int = 4096 * 4096, frames: Int = 1000, decodedBytes: Int = 32 * 1024 * 1024, minimumSide: Int = 96) {
            self.encodedBytes = encodedBytes
            self.sourceSide = sourceSide
            self.sourceArea = sourceArea
            self.frames = frames
            self.decodedBytes = decodedBytes
            self.minimumSide = minimumSide
        }

        public static let standard = Limits()
    }

    /// Browsers show frames with a delay of 10 ms or less for 100 ms;
    /// many GIFs rely on it, and a zero delay would otherwise spin. GIF
    /// delays count hundredths of a second, so 20 ms is the shortest kept.
    public static let minimumDelay: TimeInterval = 0.02
    public static let substituteDelay: TimeInterval = 0.1

    public static func normalizedDelay(_ raw: Double?) -> TimeInterval {
        guard let raw, raw.isFinite, raw >= minimumDelay else { return substituteDelay }
        return min(raw, 60)
    }

    /// Decodes `data` with its largest side at most `maxPixelSide` pixels.
    /// Returns nil for data that is not an image or that declares a size
    /// beyond `limits`. A still image decodes to one frame.
    public static func decode(_ data: Data, maxPixelSide: Int, limits: Limits = .standard) -> AnimatedImage? {
        guard !data.isEmpty, data.count <= limits.encodedBytes, maxPixelSide > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= limits.frames,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= limits.sourceSide, height <= limits.sourceSide, width * height <= limits.sourceArea
        else { return nil }

        let delays = (0..<count).map { normalizedDelay(rawDelay(source, at: $0)) }
        let plan = plan(width: width, height: height, frames: count, maxPixelSide: maxPixelSide, limits: limits)

        var frames: [CGImage] = []
        var keptDelays: [TimeInterval] = []
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: plan.side,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        // ImageIO composes each frame onto the canvas, as optimized GIFs
        // that store only changed regions need, even when frames are skipped.
        var unshown: TimeInterval = 0
        for index in stride(from: 0, to: count, by: plan.stride) {
            // A dropped or unreadable frame's time stays with the frame shown in its place.
            let time = unshown + delays[index..<min(count, index + plan.stride)].reduce(0, +)
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                if keptDelays.isEmpty { unshown = time } else { keptDelays[keptDelays.count - 1] += time; unshown = 0 }
                continue
            }
            frames.append(frame)
            keptDelays.append(time)
            unshown = 0
        }
        guard !frames.isEmpty else { return nil }
        return AnimatedImage(frames: frames, delays: keptDelays, sourcePixelSize: CGSize(width: width, height: height))
    }

    struct Plan: Equatable { let side: Int; let stride: Int }

    /// Chooses the decoded size and frame stride that keep all frames
    /// within `limits.decodedBytes`.
    static func plan(width: Int, height: Int, frames: Int, maxPixelSide: Int, limits: Limits) -> Plan {
        let longest = max(width, height)
        var side = max(1, min(longest, maxPixelSide))
        func bytes(_ side: Int, _ kept: Int) -> Int {
            let scale = Double(side) / Double(longest)
            let w = max(1, Int((Double(width) * scale).rounded(.up)))
            let h = max(1, Int((Double(height) * scale).rounded(.up)))
            return w * h * 4 * kept
        }
        if bytes(side, frames) > limits.decodedBytes {
            let shrink = (Double(limits.decodedBytes) / Double(bytes(side, frames))).squareRoot()
            side = max(1, min(side, limits.minimumSide), Int(Double(side) * shrink))
        }
        var stride = 1
        while stride < frames, bytes(side, (frames + stride - 1) / stride) > limits.decodedBytes { stride += 1 }
        return Plan(side: side, stride: stride)
    }

    private static func rawDelay(_ source: CGImageSource, at index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (container, unclamped, clamped) in containers {
            guard let values = properties[container] as? [CFString: Any] else { continue }
            if let delay = (values[unclamped] as? NSNumber)?.doubleValue, delay > 0 { return delay }
            if let delay = (values[clamped] as? NSNumber)?.doubleValue { return delay }
        }
        return nil
    }
}
