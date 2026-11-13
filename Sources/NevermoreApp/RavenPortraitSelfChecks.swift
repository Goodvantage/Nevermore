import AppKit

@MainActor enum RavenPortraitSelfChecks {
    static func run() -> [(String, Bool)] {
        let first = RavenPortrait.image(named: "alice@example.test")
        let second = RavenPortrait.image(named: "alice@example.test")
        var results = [("independently generated portraits have identical pixels for the same username", pixels(first, size: 64) != nil && pixels(first, size: 64) == pixels(second, size: 64))]
        results.append(("canonically equivalent Unicode names have identical portraits", pixels(RavenPortrait.image(named: "Amélie"), size: 32) == pixels(RavenPortrait.image(named: "Ame\u{301}lie"), size: 32)))
        let channel = RavenPortrait.channelImage(named: "general", workspace: "Engineering", access: .standard)
        let locked = RavenPortrait.channelImage(named: "general", workspace: "Engineering", access: .privateChannel)
        let repeated = RavenPortrait.channelImage(named: "general", workspace: "Engineering", access: .standard)
        results.append(("qualified channel names render consistently", pixels(channel, size: 32) != nil && pixels(channel, size: 32) == pixels(repeated, size: 32)))
        for size in [18, 32, 64] {
            let inset = Int(Double(size) * 0.12)
            let tileCorner = bitmap(channel, size: size)?.colorAt(x: inset, y: inset)?.alphaComponent ?? 0
            let portraitCorner = bitmap(first, size: size)?.colorAt(x: inset, y: inset)?.alphaComponent ?? 1
            results.append(("channel tiles have a visibly different outline from circular people at \(size) points", tileCorner > 0.95 && portraitCorner < 0.4))
            let channelSamples = (0..<64).compactMap { pixels(RavenPortrait.channelImage(named: "channel-\($0)", workspace: "Fixture", access: .standard), size: size) }
            results.append(("64 channel names produce distinct rendered tiles at \(size) points", channelSamples.count == 64 && Set(channelSamples).count == 64))
            results.append(("channel hash and private lock symbols differ at \(size) points", pixels(channel, size: size) != nil && pixels(locked, size: size) != nil && pixels(channel, size: size) != pixels(locked, size: size)))
            let samples = (0..<64).compactMap { pixels(RavenPortrait.image(named: "person-\($0)"), size: size) }
            results.append(("64 sample usernames produce distinct rendered ravens at \(size) points", samples.count == 64 && Set(samples).count == 64))
        }
        if let bitmap = bitmap(first, size: 64) {
            let corner = bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
            let center = bitmap.colorAt(x: 32, y: 32)?.alphaComponent ?? 0
            results.append(("generated portraits are non-template circles with opaque artwork", !first.isTemplate && corner < 0.01 && center > 0.99))
        } else { results.append(("generated portraits can be rasterized", false)) }
        return results
    }

    private static func pixels(_ image: NSImage, size: Int) -> Data? {
        bitmap(image, size: size)?.representation(using: .png, properties: [:])
    }

    private static func bitmap(_ image: NSImage, size: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        context.cgContext.clear(rect)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return bitmap
    }
}
