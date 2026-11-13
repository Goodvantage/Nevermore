import Foundation
import RavenProtocol

/// Bounded contiguous reading projection. Persistence/durable work are untouched.
public enum MessageWindow {
    public static let maximumRows = 500
    public static let maximumHTMLBytes = 4 * 1024 * 1024
    public static func bounded(_ messages: [RavenMessage], anchorID: String? = nil, maxRows: Int = maximumRows, maxBytes: Int = maximumHTMLBytes) -> [RavenMessage] {
        guard !messages.isEmpty, maxRows > 0, maxBytes > 0 else { return [] }
        let costs = messages.map { max(1, $0.html.utf8.count + min(4096, $0.raw["content"].string?.utf8.count ?? 0)) }
        let anchor = anchorID.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count - 1
        var lower = anchor, upper = anchor + 1, bytes = costs[anchor]
        // Always keep the requested message, even if it alone exceeds the budget;
        // the rich-text parser independently supplies its safe oversized fallback.
        let centered = anchorID != nil && messages.contains { $0.id == anchorID }
        while upper - lower < maxRows {
            let leftFits = lower > 0 && bytes <= maxBytes - min(costs[lower - 1], maxBytes)
            let rightFits = upper < messages.count && bytes <= maxBytes - min(costs[upper], maxBytes)
            if centered && rightFits && (!leftFits || upper - anchor <= anchor - lower) {
                bytes += costs[upper]; upper += 1
            } else if leftFits {
                bytes += costs[lower - 1]; lower -= 1
            } else if centered && rightFits {
                bytes += costs[upper]; upper += 1
            } else { break }
        }
        return Array(messages[lower..<upper])
    }
}
