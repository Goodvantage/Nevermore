import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

private func fixture(_ id: Int, text: String) -> RavenMessage {
    RavenMessage(raw: .object(["name": .string("m\(id)"), "channel_id": .string("c"), "text": .string(text)]))
}
@Test func transcriptWorkingSetHasBothRowAndByteBounds() {
    let rows = (0..<1000).map { fixture($0, text: String(repeating: "x", count: 1000)) }
    let window = MessageWindow.bounded(rows, maxRows: 500, maxBytes: 10_000)
    #expect(window.count == 10)
    #expect(window.first?.id == "m990" && window.last?.id == "m999")
    #expect(MessageWindow.bounded(rows, maxRows: 5).count == 5)
}
@Test func byteBoundedContextKeepsAnOpaqueAnchorAndContiguousOrder() {
    let rows = (0..<100).map { fixture($0, text: String(repeating: "é", count: 1000)) }
    let window = MessageWindow.bounded(rows, anchorID: "m50", maxBytes: 10_000)
    #expect(window.count == 5)
    #expect(window.contains { $0.id == "m50" })
    #expect(window.map(\.id) == (48...52).map { "m\($0)" })
    #expect(window.reduce(0) { $0 + $1.html.utf8.count } <= 10_000)
}
@Test func oversizedMessagesRemainVisibleThroughTheSafeFallback() {
    let huge = fixture(1, text: String(repeating: "x", count: 100))
    #expect(MessageWindow.bounded([fixture(0, text: "small"), huge], maxBytes: 10).map(\.id) == ["m1"])
    #expect(MessageWindow.bounded([huge], maxRows: 0).isEmpty)
    #expect(MessageWindow.bounded([huge], maxBytes: 0).isEmpty)
    #expect(MessageWindow.bounded([], anchorID: "missing").isEmpty)
}
