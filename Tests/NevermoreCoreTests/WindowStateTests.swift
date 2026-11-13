import Foundation
import Testing
@testable import NevermoreCore

@Test func navigationRestoresAnchorOffsetAndScopeAcrossBackForward() throws {
    var history = NavigationHistory()
    history.visit(ConversationLocation(channelID: "a"))
    let reading = ConversationLocation(channelID: "a", anchorMessageID: "opaque:message", pixelOffset: -19.5, searchText: "scoped query")
    history.capture(reading); history.visit(ConversationLocation(channelID: "b"))
    #expect(history.back() == reading)
    #expect(history.forward()?.channelID == "b")
    #expect(try JSONDecoder().decode(NavigationHistory.self, from: JSONEncoder().encode(history)) == history)
}
@Test func visitingANewConversationTruncatesForwardNavigationAndBoundsMemory() {
    var history = NavigationHistory()
    history.visit(ConversationLocation(channelID: "a")); history.visit(ConversationLocation(channelID: "b")); _ = history.back()
    history.visit(ConversationLocation(channelID: "c")); #expect(!history.canGoForward)
    for index in 0..<100 { history.visit(ConversationLocation(channelID: String(index))) }
    #expect(history.entries.count == 50)
    #expect(history.current?.channelID == "99")
    history.capture(ConversationLocation(channelID: "wrong", anchorMessageID: "wrong"))
    #expect(history.current?.channelID == "99")
}
@Test func savedWindowStatePreservesAccountIdentityWithoutMessageContent() throws {
    let state = SavedWindowState(windowID: UUID(), accountID: UUID(), location: ConversationLocation(channelID: "opaque", anchorMessageID: "anchor", pixelOffset: 12, threadParentChannelID: "parent-channel"), workspaceID: "workspace-id", frame: .init(x: 10, y: 20, width: 1080, height: 760), threadRootID: "root")
    #expect(try JSONDecoder().decode(SavedWindowState.self, from: JSONEncoder().encode(state)) == state)
    #expect(state.frame?.isValid == true)
    #expect(!SavedWindowState.Frame(x: .nan, y: 0, width: 1080, height: 760).isValid)
    #expect(!SavedWindowState.Frame(x: 0, y: 0, width: 10, height: 760).isValid)
    #expect(ConversationLocation(channelID: "a", pixelOffset: .infinity).pixelOffset == 0)
}
@Test func savedWindowStateKeepsTabGroupsAndReadsEarlierStates() throws {
    let leader = UUID()
    let tab = SavedWindowState(windowID: UUID(), accountID: UUID(), location: ConversationLocation(channelID: "second"), tabGroupID: leader)
    #expect(try JSONDecoder().decode(SavedWindowState.self, from: JSONEncoder().encode(tab)) == tab)
    // States written before tab restoration have no tabGroupID key and must
    // still restore as standalone windows.
    let earlier = #"{"version":1,"windowID":"7D3C9C55-6E57-4A36-9A6B-3C0D7F2B6A11","accountID":"0B7F9D2E-1A4C-4B8E-9E3D-2C5A6F7B8C9D","location":{"channelID":"general","pixelOffset":0,"searchText":""},"workspaceID":"All Workspaces"}"#
    let decoded = try JSONDecoder().decode(SavedWindowState.self, from: Data(earlier.utf8))
    #expect(decoded.tabGroupID == nil)
    #expect(decoded.location.channelID == "general")
    #expect(decoded.version == 1)
}
