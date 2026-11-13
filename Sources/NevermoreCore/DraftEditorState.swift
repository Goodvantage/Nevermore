import Foundation

/// Local authoring state. Source is durable even when it cannot yet be sent.
public struct DraftEditorState: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case visual, markdown }
    public var mode: Mode
    public var source: String
    public var selection: Int
    public var selectionLength: Int

    public init(mode: Mode = .visual, source: String = "", selection: Int = 0, selectionLength: Int = 0) {
        self.mode = mode
        self.source = source
        self.selection = selection
        self.selectionLength = selectionLength
    }

    /// Selection belongs to a view, not the message being accepted. Moving
    /// the caret must not make an otherwise unchanged draft stale.
    public static func sameContent(_ lhs: Self?, _ rhs: Self?) -> Bool {
        let leftMode = lhs?.mode ?? .visual, rightMode = rhs?.mode ?? .visual
        return leftMode == rightMode && (leftMode == .visual || lhs?.source == rhs?.source)
    }
}

extension Draft {
    /// Always derive the outgoing body from the active representation. A
    /// previously valid HTML cache must never mask unfinished source edits.
    public func validatedHTML() throws -> String {
        if let editorState, editorState.mode == .markdown {
            return RichTextCodec.html(try RavenMarkdown.document(from: editorState.source))
        }
        let document = try RichTextCodec.parse(html)
        guard document.canEdit else { throw RichTextError.unsafeEdit }
        return RichTextCodec.html(document)
    }
}
