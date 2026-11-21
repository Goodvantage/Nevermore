import Testing
@testable import NevermoreCore

@Suite struct NotificationPreviewTests {
    private func text(_ level: NotificationPreview, direct: Bool = false, multiple: Bool = false, text: String? = "Ship it today", file: String? = nil) -> NotificationText {
        NotificationText.make(level: level, account: "Acme", multipleAccounts: multiple, conversation: "launch", isDirect: direct, sender: "Morgan Lee", text: text, file: file)
    }

    @Test func structuredTeasersMaskMarkedUpSpoilers() {
        let raw = #"<p>Poll: <span data-spoiler="true">secret</span></p>"#
        #expect(NotificationText.structuredTeaser(raw) == "Poll: [Spoiler]")
        #expect(NotificationText.structuredTeaser("Budget & schedule") == "Budget & schedule")
    }

    @Test func unsetOrUnknownLevelsStayGeneric() {
        #expect(NotificationPreview.level(stored: nil) == .generic)
        #expect(NotificationPreview.level(stored: "everything") == .generic)
        #expect(NotificationPreview.level(stored: "message") == .message)
    }

    @Test func genericRevealsNothingAboutTheMessage() {
        #expect(text(.generic) == NotificationText(title: "Acme", subtitle: "", body: "New activity in Raven"))
        #expect(text(.generic, direct: true, multiple: true) == NotificationText(title: "Acme", subtitle: "", body: "New activity in Raven"))
    }

    @Test func senderLevelNamesWhoAndWhereOnly() {
        #expect(text(.sender) == NotificationText(title: "#launch", subtitle: "", body: "New message from Morgan Lee"))
        #expect(text(.sender, direct: true) == NotificationText(title: "Morgan Lee", subtitle: "", body: "New message"))
        #expect(text(.sender, multiple: true).subtitle == "Acme")
    }

    @Test func messageLevelShowsTheText() {
        #expect(text(.message) == NotificationText(title: "#launch", subtitle: "", body: "Morgan Lee: Ship it today"))
        #expect(text(.message, direct: true).body == "Ship it today")
        let long = text(.message, text: String(repeating: "word ", count: 100)).body
        #expect(long.hasPrefix("Morgan Lee: ") && long.hasSuffix("…") && long.count <= "Morgan Lee: ".count + NotificationText.excerptLimit + 1)
        #expect(text(.message, text: nil, file: "report.pdf").body == "Morgan Lee: Sent report.pdf")
        #expect(text(.message, text: "  \n ", file: nil).body == "Morgan Lee: New message")
    }

    @Test func excerptsFoldWhitespaceAndCutAtAWord() {
        #expect(NotificationText.excerpt("one\n\n two\tthree") == "one two three")
        let long = Array(repeating: "word", count: 100).joined(separator: " ")
        let cut = NotificationText.excerpt(long)
        #expect(cut?.hasSuffix("word…") == true)
        #expect((cut?.count ?? 0) <= NotificationText.excerptLimit + 1)
        let unbroken = String(repeating: "x", count: 400)
        #expect(NotificationText.excerpt(unbroken) == String(repeating: "x", count: NotificationText.excerptLimit) + "…")
    }
}
