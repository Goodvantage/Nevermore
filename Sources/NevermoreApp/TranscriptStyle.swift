import AppKit
import UniformTypeIdentifiers
import RavenProtocol
import NevermoreCore

extension NSAttributedString.Key {
    // The "Nevermore." prefix keeps these out of copied text.
    /// A `TranscriptAvatar`, on the first character of a sender header.
    static let nevermoreAvatar = NSAttributedString.Key("Nevermore.Avatar")
    /// Marks a day divider label; the transcript draws its rule and pill.
    static let nevermoreDayDivider = NSAttributedString.Key("Nevermore.DayDivider")
    /// One reaction; the value is true when it includes the reader's.
    static let nevermoreReactionChip = NSAttributedString.Key("Nevermore.ReactionChip")
    /// Short time of a message shown without a header, drawn in the avatar
    /// column while the message is hovered or selected.
    static let nevermoreGutterTime = NSAttributedString.Key("Nevermore.GutterTime")
    /// Replaces the run's text in copies, so a header showing "12:23"
    /// copies with its date.
    static let nevermoreCopyText = NSAttributedString.Key("Nevermore.CopyText")
    /// A reply quote; the value is the color of the bar drawn beside it.
    static let nevermoreQuoteBar = NSAttributedString.Key("Nevermore.QuoteBar")
}

/// Who sent a group of messages, drawn in the column left of the text.
final class TranscriptAvatar: NSObject {
    let userID: String
    let initials: String
    let color: NSColor

    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen, .systemIndigo, .systemRed, .systemBrown]

    init(userID: String, name: String) {
        self.userID = userID
        initials = AvatarMonogram.initials(for: name)
        color = Self.color(for: userID)
    }

    /// The author's color for monograms and reply bars: under a palette
    /// theme the color their name has, so avatar, name and bar agree.
    static func color(for userID: String) -> NSColor {
        if let theme = ActiveThemePalette.current { return NSColor(theme: theme.nameColor(for: userID)) }
        return palette[AvatarMonogram.paletteIndex(for: userID, count: palette.count)]
    }
}

/// Sizes derived from the reading text size, so ⌘+ scales the layout.
struct TranscriptMetrics: Equatable {
    let size: CGFloat
    let compact: Bool

    /// Compact mode drops avatars and their column, as in Slack.
    var avatarDiameter: CGFloat { compact ? 0 : (size * 2.3).rounded() }
    var gutter: CGFloat { compact ? 0 : avatarDiameter + 12 }
    /// Blank space after a message whose sender continues, and after the
    /// last message of a group.
    var continuationGap: CGFloat { compact ? 0 : max(3, (size * 0.3).rounded()) }
    var groupGap: CGFloat { compact ? 0 : (size * 1.15).rounded() }
    /// Compact rows have no blank separator line, so headers carry the gap.
    var compactHeaderSpacing: CGFloat { compact ? 4 : 0 }
    var detailSize: CGFloat { max(10, size - 3) }
    /// Extra leading in message bodies; 14 pt text gets 17 pt lines plus 3.
    var bodyLineSpacing: CGFloat { (size * 0.2).rounded() }
    var chipFont: NSFont { .systemFont(ofSize: max(11, size - 1)) }
    var chipPadding: CGFloat { (size * 0.5).rounded() }
    var chipVerticalPadding: CGFloat { (size * 0.25).rounded() }
}

/// Typographic hierarchy for the transcript, after Slack: an avatar and
/// prominent sender once per group, quiet times, day dividers, and system
/// events set apart from conversation. Separators keep the characters
/// earlier builds used (one or two newlines, by the compact setting), so
/// ranges, copying and accessibility are unchanged.
@MainActor enum TranscriptStyle {
    /// Centered paragraphs (dividers, system events). The text container
    /// starts right of the avatar column; the negative tail indent moves the
    /// center back to the middle of the pane.
    static func centered(_ metrics: TranscriptMetrics, before: CGFloat, after: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        style.tailIndent = -metrics.gutter; style.paragraphSpacingBefore = before; style.paragraphSpacing = after
        return style
    }
    /// The message a reply answers, as a quote with a bar in its author's
    /// color. Copies as "↪ Name: text", as earlier builds showed it.
    static func replyQuote(author: (name: String, id: String)?, preview: String, metrics: TranscriptMetrics) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 11; style.headIndent = 11; style.paragraphSpacing = 3; style.paragraphSpacingBefore = 2
        let font = NSFont.systemFont(ofSize: max(11, metrics.size - 1))
        let bar = author.map { TranscriptAvatar.color(for: $0.id) } ?? NSColor.themeTertiaryText
        let output = NSMutableAttributedString()
        if let author {
            output.append(NSAttributedString(string: author.name, attributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), .foregroundColor: NSColor.themeSecondaryText, .nevermoreCopyText: "↪ \(author.name)\(preview.isEmpty ? "" : ":")"]))
            if !preview.isEmpty { output.append(NSAttributedString(string: "  " + preview, attributes: [.font: font, .foregroundColor: NSColor.themeSecondaryText])) }
        } else {
            output.append(NSAttributedString(string: "Reply to an earlier message", attributes: [.font: font, .foregroundColor: NSColor.themeTertiaryText, .nevermoreCopyText: "↪ a message"]))
        }
        output.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        output.addAttributes([.paragraphStyle: style, .nevermoreQuoteBar: bar], range: NSRange(location: 0, length: output.length))
        return output
    }

    static func header(name: String, authorID: String, time: String, fullTime: String, avatar: TranscriptAvatar?, metrics: TranscriptMetrics) -> NSAttributedString {
        let style = NSMutableParagraphStyle(); style.paragraphSpacing = 1; style.paragraphSpacingBefore = metrics.compactHeaderSpacing
        var nameAttributes = ThemeFonts.senderNameAttributes(for: authorID)
        nameAttributes[.font] = ThemeFonts.senderName(ofSize: max(12, metrics.size)); nameAttributes[.paragraphStyle] = style
        let output = NSMutableAttributedString(string: name, attributes: nameAttributes)
        if let avatar, output.length > 0 { output.addAttribute(.nevermoreAvatar, value: avatar, range: NSRange(location: 0, length: 1)) }
        output.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: metrics.detailSize), .paragraphStyle: style]))
        output.append(NSAttributedString(string: time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.detailSize, weight: .regular), .foregroundColor: NSColor.themeSecondaryText, .paragraphStyle: style, .toolTip: fullTime, .nevermoreCopyText: fullTime]))
        output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: metrics.detailSize), .paragraphStyle: style]))
        return output
    }

    /// "Today", centered on a hairline. A reading control: headers copy
    /// with full timestamps instead.
    static func dayDivider(_ label: String, metrics: TranscriptMetrics) -> NSAttributedString {
        NSAttributedString(string: label + "\n", attributes: [.font: NSFont.systemFont(ofSize: max(11, metrics.size - 2), weight: .semibold), .foregroundColor: NSColor.themeSecondaryText, .nevermoreReadingControl: true, .nevermoreDayDivider: true, .paragraphStyle: centered(metrics, before: metrics.compact ? 8 : 12, after: metrics.compact ? 4 : 8)])
    }

    static func unreadDivider(metrics: TranscriptMetrics) -> NSAttributedString {
        NSAttributedString(string: "Unread messages\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.themeAlert, .nevermoreReadingControl: true, .nevermoreUnreadDivider: true, .paragraphStyle: centered(metrics, before: 4, after: 6)])
    }

    /// "Benedikt added Lukas.  12:23", small and centered, without a sender
    /// header: an event in the conversation rather than part of it.
    static func systemEvent(_ text: String, time: String, fullTime: String, metrics: TranscriptMetrics) -> NSAttributedString {
        let style = centered(metrics, before: metrics.compact ? 2 : 4, after: 0)
        let output = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: max(11, metrics.size - 2)), .foregroundColor: NSColor.themeSecondaryText, .paragraphStyle: style])
        output.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: metrics.detailSize), .paragraphStyle: style]))
        output.append(NSAttributedString(string: time, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: metrics.detailSize, weight: .regular), .foregroundColor: NSColor.themeTertiaryText, .paragraphStyle: style, .toolTip: fullTime, .nevermoreCopyText: fullTime]))
        return output
    }

    /// The end of a message: a newline, then (outside compact mode) a blank
    /// line whose height spaces messages within and between groups.
    static func separator(metrics: TranscriptMetrics, nextContinuesGroup: Bool) -> NSAttributedString {
        guard !metrics.compact else { return NSAttributedString(string: "\n") }
        let height = nextContinuesGroup ? metrics.continuationGap : metrics.groupGap
        let style = NSMutableParagraphStyle(); style.minimumLineHeight = height; style.maximumLineHeight = height
        // The first newline ends the message's last paragraph and keeps its
        // style; only the blank line gets the fixed height.
        let output = NSMutableAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 7)])
        output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 7), .paragraphStyle: style]))
        return output
    }

    /// Reactions as rounded chips, the reader's own tinted. Copies as
    /// "👍 2   🎉 1".
    static func reactions(_ chips: [ReactionChip], metrics: TranscriptMetrics) -> NSAttributedString {
        let padding = metrics.chipPadding, vertical = metrics.chipVerticalPadding
        // Chips are drawn larger than their line; spacing keeps them clear
        // of the text above and of each other when a narrow pane wraps them.
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = padding; style.headIndent = padding
        style.paragraphSpacingBefore = vertical + 4; style.lineSpacing = vertical * 2 + 4
        let font = metrics.chipFont
        // The leading newline ends the body paragraph, which keeps its style.
        let output = NSMutableAttributedString(string: "\n", attributes: [.font: font])
        for (index, chip) in chips.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "   ", attributes: [.font: font, .paragraphStyle: style, .kern: padding * 0.6])) }
            output.append(NSAttributedString(string: "\(chip.label) \(chip.count)", attributes: [.font: font, .foregroundColor: chip.includesCurrentUser ? NSColor.themeAccentText : NSColor.themeSecondaryText, .paragraphStyle: style, .nevermoreReactionChip: chip.includesCurrentUser]))
        }
        return output
    }

    /// Opens up message bodies, which otherwise use the tight default
    /// leading. Table cells keep their own layout.
    static func addLineSpacing(_ spacing: CGFloat, to text: NSMutableAttributedString, in range: NSRange) {
        var updates: [(NSRange, NSParagraphStyle)] = []
        text.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            let current = value as? NSParagraphStyle
            guard current?.textBlocks.isEmpty != false, (current?.lineSpacing ?? 0) == 0 else { return }
            let style = (current ?? .default).mutableCopy() as! NSMutableParagraphStyle
            style.lineSpacing = spacing
            updates.append((run, style))
        }
        for (run, style) in updates { text.addAttribute(.paragraphStyle, value: style, range: run) }
    }

    /// "[icon] report.pdf  Space to Quick Look". The icon is a reading
    /// control, so copying the transcript yields only the file name.
    static func attachmentLine(filename: String, size: CGFloat) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "\n")
        let icon = NSTextAttachment(); icon.image = fileIcon(for: (filename as NSString).pathExtension)
        icon.bounds = NSRect(x: 0, y: -4, width: size + 4, height: size + 4)
        let iconString = NSMutableAttributedString(attachment: icon)
        iconString.append(NSAttributedString(string: " "))
        iconString.addAttribute(.nevermoreReadingControl, value: true, range: NSRange(location: 0, length: iconString.length))
        output.append(iconString)
        output.append(NSAttributedString(string: filename, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.themeLink]))
        output.append(NSAttributedString(string: "  Space to Quick Look", attributes: [.font: NSFont.systemFont(ofSize: max(10, size - 3)), .foregroundColor: NSColor.themeTertiaryText, .nevermoreReadingControl: true]))
        return output
    }

    /// A staged file in a message that has not been sent yet: the name
    /// alone, since there is nothing on the server to Quick Look.
    static func pendingAttachmentLine(filename: String, size: CGFloat, first: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: first ? "" : "\n")
        let icon = NSTextAttachment(); icon.image = fileIcon(for: (filename as NSString).pathExtension)
        icon.bounds = NSRect(x: 0, y: -4, width: size + 4, height: size + 4)
        let iconString = NSMutableAttributedString(attachment: icon)
        iconString.append(NSAttributedString(string: " "))
        iconString.addAttribute(.nevermoreReadingControl, value: true, range: NSRange(location: 0, length: iconString.length))
        output.append(iconString)
        output.append(NSAttributedString(string: filename, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.themeText]))
        return output
    }

    /// "Not sent · Needs review · reason", under a send the outbox cannot
    /// finish by itself. A reading control: it is not part of the message.
    static func pendingStatus(state: String, error: String?, metrics: TranscriptMetrics) -> NSAttributedString {
        let detail = [state, error].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return NSAttributedString(string: "\nNot sent · \(detail)", attributes: [.font: NSFont.systemFont(ofSize: metrics.detailSize), .foregroundColor: NSColor.themeAlert, .nevermoreReadingControl: true])
    }

    private static var iconCache: [String: NSImage] = [:]
    /// File-type icons, cached per extension: a long transcript re-renders
    /// often and would otherwise ask NSWorkspace for every attachment.
    static func fileIcon(for pathExtension: String) -> NSImage {
        let key = pathExtension.lowercased()
        if let cached = iconCache[key] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: key) ?? .data)
        if iconCache.count < 256 { iconCache[key] = icon }
        return icon
    }
}

// MARK: - Drawing

/// Decorations the text system cannot draw: avatars, divider rules, reaction
/// chips and the hover time. They are attributes on the text, so they move
/// with layout, and drawing visits only the visible part of the transcript.
extension TranscriptView {
    func drawDecorations(in dirtyRect: NSRect) {
        guard let storage = textStorage, storage.length > 0, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        // Reach far enough up to catch the header of an avatar whose lower
        // half is the first visible line.
        let reach = max(80, metrics.avatarDiameter * 2)
        let search = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -4000, dy: -reach)
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: search, in: container)
        let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard visible.length > 0 else { return }

        func lineRect(at location: Int) -> NSRect? {
            guard location < storage.length else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: location)
            guard glyph < layout.numberOfGlyphs else { return nil }
            return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true).offsetBy(dx: origin.x, dy: origin.y)
        }
        func labelRect(_ range: NSRange) -> NSRect {
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphRange, in: container).offsetBy(dx: origin.x, dy: origin.y)
        }
        let left = readingColumnInset, right = bounds.width - readingColumnInset

        // Per attribute, not per run: font fallback splits "👍 2" into an
        // emoji run and a text run, which must still make one chip.
        let text = storage.string as NSString
        for key in [NSAttributedString.Key.nevermoreDayDivider, .nevermoreUnreadDivider] {
            storage.enumerateAttribute(key, in: visible) { value, range, _ in
                guard value as? Bool == true else { return }
                var label = range
                if text.character(at: NSMaxRange(range) - 1) == 10 { label.length -= 1 }
                guard label.length > 0 else { return }
                let rect = labelRect(label)
                guard rect.insetBy(dx: -4000, dy: -12).intersects(dirtyRect) else { return }
                let y = rect.midY.rounded() + 0.5
                if key == .nevermoreUnreadDivider {
                    drawRule(y: y, from: left, to: right, gap: rect.insetBy(dx: -10, dy: 0), color: NSColor.themeAlert.withAlphaComponent(0.55))
                    return
                }
                let pill = rect.insetBy(dx: -12, dy: -4)
                drawRule(y: y, from: left, to: right, gap: pill, color: .separatorColor)
                let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
                NSColor.textBackgroundColor.setFill(); path.fill()
                NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
            }
        }
        storage.enumerateAttribute(.nevermoreReactionChip, in: visible) { value, range, _ in
            guard let mine = value as? Bool else { return }
            for chip in chipRects(for: range) where chip.intersects(dirtyRect) {
                let path = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
                (mine ? NSColor.themeAccent.withAlphaComponent(0.16) : NSColor.tertiarySystemFill).setFill(); path.fill()
                (mine ? NSColor.themeAccent.withAlphaComponent(0.55) : NSColor.separatorColor).setStroke(); path.lineWidth = 1; path.stroke()
            }
        }
        storage.enumerateAttribute(.nevermoreQuoteBar, in: visible) { value, range, _ in
            guard let color = value as? NSColor else { return }
            var quote = range
            if text.character(at: NSMaxRange(range) - 1) == 10 { quote.length -= 1 }
            guard quote.length > 0 else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)
            var lines = NSRect.null
            layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in lines = lines.union(used) }
            guard !lines.isNull else { return }
            let bar = NSRect(x: origin.x + container.lineFragmentPadding, y: lines.minY + origin.y + 1, width: 3, height: max(0, lines.height - 2))
            guard bar.intersects(dirtyRect) else { return }
            color.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
        if metrics.avatarDiameter > 0 {
            storage.enumerateAttribute(.nevermoreAvatar, in: visible) { value, range, _ in
                guard let avatar = value as? TranscriptAvatar, let line = lineRect(at: range.location) else { return }
                let rect = NSRect(x: left, y: line.minY + 2, width: metrics.avatarDiameter, height: metrics.avatarDiameter)
                if rect.intersects(dirtyRect) { drawAvatar(avatar, in: rect) }
            }
        }

        // Compact rows have no column to show the time in.
        for location in Set([hoverMessageLocation, caretMessageLocation].compactMap { $0 }) where metrics.gutter > 0 && location < storage.length && NSLocationInRange(location, visible) {
            guard let time = storage.attribute(.nevermoreGutterTime, at: location, effectiveRange: nil) as? String, let line = lineRect(at: location) else { continue }
            let glyph = layout.glyphIndexForCharacter(at: location)
            let baseline = line.minY + layout.location(forGlyphAt: glyph).y
            // Right-aligned in the column, shrunk rather than spilling into the text.
            let room = origin.x - 8 - left
            var font = NSFont.monospacedDigitSystemFont(ofSize: metrics.detailSize, weight: .regular)
            let natural = NSAttributedString(string: time, attributes: [.font: font]).size().width
            if natural > room {
                let size = (metrics.detailSize * room / natural).rounded(.down)
                guard size >= 8 else { continue }
                font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
            }
            let text = NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: NSColor.themeTertiaryText])
            text.draw(at: NSPoint(x: origin.x - 8 - text.size().width, y: baseline - font.ascender))
        }
    }

    /// The pill of the reaction chip at `range`, in view coordinates: one
    /// per line the chip occupies, should a narrow pane wrap it. Its
    /// height follows the chip font around the baseline; line rectangles
    /// also hold the paragraph's spacing. Drawing and the sticker
    /// animations share this, so stickers land exactly on chips.
    func chipRects(for range: NSRange) -> [NSRect] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        let origin = textContainerOrigin
        let chipFont = metrics.chipFont
        let padding = metrics.chipPadding, vertical = metrics.chipVerticalPadding
        var result: [NSRect] = []
        let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            let glyph = layout.glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY), in: container)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let baseline = line.minY + layout.location(forGlyphAt: glyph).y + origin.y
            result.append(NSRect(x: rect.minX + origin.x - padding, y: baseline - chipFont.ascender - vertical, width: rect.width + padding * 2, height: chipFont.ascender - chipFont.descender + vertical * 2))
        }
        return result
    }

    private func drawRule(y: CGFloat, from left: CGFloat, to right: CGFloat, gap: NSRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1
        if gap.minX > left { path.move(to: NSPoint(x: left, y: y)); path.line(to: NSPoint(x: gap.minX, y: y)) }
        if gap.maxX < right { path.move(to: NSPoint(x: gap.maxX, y: y)); path.line(to: NSPoint(x: right, y: y)) }
        path.stroke()
    }

    private func drawAvatar(_ avatar: TranscriptAvatar, in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        if let image = avatarImage?(avatar.userID) {
            ProfilePhoto.draw(image, in: rect)
            return
        }
        avatar.color.withAlphaComponent(0.22).setFill(); circle.fill()
        let font = NSFont.systemFont(ofSize: (rect.height * (avatar.initials.count > 1 ? 0.36 : 0.42)).rounded(), weight: .semibold)
        let text = NSAttributedString(string: avatar.initials, attributes: [.font: font, .foregroundColor: avatar.color])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
