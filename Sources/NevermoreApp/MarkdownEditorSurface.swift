import AppKit
import SwiftUI
import MarkdownEngine

@MainActor final class MarkdownEditorState: ObservableObject {
    @Published var text = ""
    @Published var isEditable = true
    @Published var placeholder = ""
    @Published var documentID = UUID().uuidString
    weak var owner: (any MarkdownClipboardOwner)?
}

struct MarkdownEditorSurface: View {
    @ObservedObject var state: MarkdownEditorState
    var body: some View {
        var configuration = MarkdownEditorConfiguration.default
        // Source is literal, including the HTML islands which preserve Raven
        // mentions, emoji and formatting not expressible in CommonMark.
        configuration.rawSourceMode = true
        configuration.overscroll.percent = 0
        configuration.textInsets = TextInsets(horizontal: 10, vertical: 10)
        configuration.spellChecking.automaticQuoteSubstitution = false
        configuration.spellChecking.automaticSpellingCorrection = false
        return NativeTextViewWrapper(text: $state.text, configuration: configuration,
                                     fontName: "Menlo", fontSize: 13, documentId: state.documentID, isEditable: state.isEditable,
                                     onBuildContextMenu: { menu, _ in ComposerClipboard.sourceMenu(menu, owner: state.owner) },
                                     placeholder: NSAttributedString(string: state.placeholder, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.placeholderTextColor]))
    }
}

