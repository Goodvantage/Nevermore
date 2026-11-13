import Foundation

public enum MessageDocumentResult: Sendable, Equatable {
    case parsed(RichDocument)
    case failed
}

/// Account-local value documents only. Presentation objects and command routes
/// must still be constructed separately for every message and render.
public struct MessageDocumentCache: Sendable {
    private struct Key: Hashable, Sendable {
        let channel: [UInt8]
        let message: [UInt8]

        init?(channelID: String, messageID: String) {
            let channel = Array(channelID.utf8.prefix(8193))
            guard channel.count <= 8192 else { return nil }
            let message = Array(messageID.utf8.prefix(8193 - channel.count))
            guard message.count <= 8192 - channel.count else { return nil }
            self.channel = channel; self.message = message
        }
    }
    private struct Entry: Sendable {
        let html: String
        let result: MessageDocumentResult
        let bytes: Int
        let nodes: Int
        var lastAccess: UInt64
    }
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let maximumNodes: Int
    private let parse: @Sendable (String) throws -> RichDocument
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var nodes = 0
    private var access: UInt64 = 0

    public init() { self.init(parse: RichTextCodec.parse) }

    // The parser seam measures actual avoided work in tests. Production always
    // uses RichTextCodec, including its independent source/depth/node limits.
    init(maximumEntries: Int = 1000, maximumBytes: Int = 8 * 1024 * 1024, maximumNodes: Int = 100_000, parse: @escaping @Sendable (String) throws -> RichDocument = RichTextCodec.parse) {
        precondition(maximumEntries >= 0 && maximumBytes >= 0 && maximumNodes >= 0)
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes; self.maximumNodes = maximumNodes; self.parse = parse
    }

    public mutating func document(channelID: String, messageID: String, html: String) -> MessageDocumentResult {
        if access == .max { removeAll() }
        access += 1
        let key = Key(channelID: channelID, messageID: messageID)
        if let key, var entry = entries[key] {
            // Swift String equality is canonically equivalent, while edits and
            // opaque identities here must preserve exact source bytes.
            if entry.html.utf8.elementsEqual(html.utf8) {
                entry.lastAccess = access; entries[key] = entry
                return entry.result
            }
            remove(key)
        }
        let result: MessageDocumentResult
        do { result = .parsed(try parse(html)) }
        catch { result = .failed }
        guard let key, maximumEntries > 0, let cost = cost(result, html: html, key: key) else { return result }
        while entries.count >= maximumEntries || bytes > maximumBytes - cost.bytes || nodes > maximumNodes - cost.nodes {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            remove(oldest)
        }
        entries[key] = Entry(html: html, result: result, bytes: cost.bytes, nodes: cost.nodes, lastAccess: access)
        bytes += cost.bytes; nodes += cost.nodes
        return result
    }

    public mutating func removeAll() {
        entries.removeAll(); bytes = 0; nodes = 0; access = 0
    }

    private mutating func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.bytes; nodes -= entry.nodes
    }

    /// Conservatively estimate UTF-8 source/key/document payloads separately
    /// from the node limit, which bounds tree/container overhead. No rendering
    /// objects, errors, timestamps or account metadata enter an entry.
    private func cost(_ result: MessageDocumentResult, html: String, key: Key) -> (bytes: Int, nodes: Int)? {
        var bytes = 0
        func add(_ count: Int) -> Bool {
            guard count <= maximumBytes - bytes else { return false }
            bytes += count
            return true
        }
        guard add(key.channel.count), add(key.message.count), add(html.utf8.count) else { return nil }
        var nodes = 0
        if case .parsed(let document) = result {
            guard add(document.rawHTML.utf8.count) else { return nil }
            for warning in document.warnings { guard add(warning.utf8.count) else { return nil } }
            var pending = document.nodes
            while let node = pending.popLast() {
                guard nodes < maximumNodes else { return nil }
                nodes += 1
                switch node {
                case .text(let text): guard add(text.utf8.count) else { return nil }
                case .element(let tag, let attributes, let children):
                    guard add(tag.utf8.count) else { return nil }
                    for (key, value) in attributes { guard add(key.utf8.count), add(value.utf8.count) else { return nil } }
                    pending.append(contentsOf: children)
                }
            }
        }
        return (bytes, nodes)
    }
}
