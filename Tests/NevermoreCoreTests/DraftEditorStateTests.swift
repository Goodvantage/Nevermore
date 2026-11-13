import Foundation
import Testing
@testable import NevermoreCore

struct DraftEditorStateTests {
    @Test func oldDraftsDecodeAsVisual() throws {
        let data = Data(#"{"channelID":"general","html":"<p>old</p>","attachments":[],"caret":2}"#.utf8)
        let draft = try JSONDecoder().decode(Draft.self, from: data)
        #expect(draft.editorState == nil)
        #expect(try draft.validatedHTML() == "<p>old</p>")
    }

    @Test func literalSourceAndSelectionSurvivePersistence() throws {
        let source = "# unfinished\n\n```swift\n  literal  \t\n"
        let draft = Draft(channelID: "general", html: "<p>previous</p>", editorState: DraftEditorState(mode: .markdown, source: source, selection: 3, selectionLength: 4))
        let decoded = try JSONDecoder().decode(Draft.self, from: JSONEncoder().encode(draft))
        #expect(decoded == draft)
        #expect(throws: (any Error).self) { try decoded.validatedHTML() }
    }

    @Test func undoSendCannotOverwriteUnfinishedSource() {
        let draft = Draft(channelID: "general", editorState: DraftEditorState(mode: .markdown, source: "# unfinished"))
        #expect(!InkRules.canRestoreDraft(draft))
    }

    @Test func undoSendJudgesEmptySourceWithoutItsHTMLCache() {
        var draft = Draft(channelID: "general", html: "<p>stale</p>", editorState: DraftEditorState(mode: .markdown))
        #expect(InkRules.canRestoreDraft(draft))
        draft.replyTo = "message"
        #expect(!InkRules.canRestoreDraft(draft))
        draft.replyTo = nil
        draft.editorState?.source = " "
        #expect(!InkRules.canRestoreDraft(draft)) // Literal source whitespace is still work.
    }

    @Test func sourceDeterminesOutgoingHTML() throws {
        let draft = Draft(channelID: "general", html: "<p>stale</p>", editorState: DraftEditorState(mode: .markdown, source: "**current**"))
        #expect(try draft.validatedHTML() == "<p><strong>current</strong></p>")
    }

    @Test func invalidSourceCannotBeAcceptedAndRemainsRecoverable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AccountStore(directory: directory)
        let draft = Draft(channelID: "general", html: "<p>stale</p>", editorState: DraftEditorState(mode: .markdown, source: "# unsupported heading"))
        try await store.saveDraft(draft)
        await #expect(throws: (any Error).self) { try await store.acceptDraft(channelID: "general", expected: draft) }
        #expect(try await store.draft(channelID: "general") == draft)
        #expect(try await store.operations().isEmpty)
    }

    @Test func acceptanceChecksSourceThenClearsItAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AccountStore(directory: directory)
        let first = Draft(channelID: "general", html: "<p>same cache</p>", editorState: DraftEditorState(mode: .markdown, source: "first"))
        let second = Draft(channelID: "general", html: first.html, editorState: DraftEditorState(mode: .markdown, source: "second"))
        try await store.saveDraft(second)
        await #expect(throws: (any Error).self) { try await store.acceptDraft(channelID: "general", expected: first) }
        var movedCaret = second
        movedCaret.editorState?.selection = 3
        let operation = try await store.acceptDraft(channelID: "general", expected: movedCaret)
        #expect(operation.html == "<p>second</p>")
        #expect(try await store.draft(channelID: "general") == nil)
    }
}
