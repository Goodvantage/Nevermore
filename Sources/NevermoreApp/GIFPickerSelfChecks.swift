import AppKit
import NevermoreCore
import RavenProtocol

/// Send GIF: the picker searches the reader's service, shows playing
/// previews with the service's attribution, and a choice becomes a queued
/// GIF message beside the draft, carrying the reply in progress. Fixtures
/// only; nothing reaches a GIF service or Raven.
@MainActor enum GIFPickerSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreGIFPickerCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "gif-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("gif-picker"), "channel_name": .string("GIF picker")]))
        session.channels = [channel]
        try await session.store.cacheChannels(session.channels)
        try await session.store.cacheMessages([RavenMessage(raw: .object(["name": .string("question"), "channel_id": .string(channel.id), "owner": .string("alice@example.invalid"), "creation": .string("2026-11-06 09:00:00.000000"), "text": .string("<p>How was the launch?</p>"), "message_type": .string("Text")]))])
        // Offline, so a chosen GIF stays queued where it can be inspected.
        let wire = DemoWire(session: session); wire.network = .offline
        session.demoWire = wire
        let media = PickerFixtureMedia(data: AnimatedImageSelfChecks.gif(width: 80, height: 60))
        session.gifMedia = media
        let search = PickerFixtureSearch()
        let controller = ConversationWindow(app: app, session: session)
        controller.gifSourcesOverride = GIFPickerSheet.Sources(search: search, provider: .klipy, media: media)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        await controller.loadTask?.value; await controller.renderTask?.value
        guard let parent = controller.window else { return [("GIF picker fixture has a window", false)] }

        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<300 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }

        // A draft and a reply are in progress when the reader picks a GIF.
        try await session.save(Draft(channelID: channel.id, html: "<p>half written</p>", replyTo: "question"))
        controller.restoreDraft()
        let replying = await wait { controller.replyTo == "question" }
        check("the draft comes back with its reply", replying)

        controller.sendGIF(nil)
        let opened = await wait { GIFPickerSheet.current != nil && parent.attachedSheet != nil }
        guard opened, let sheet = GIFPickerSheet.current else { return checks + [("Send GIF opens the picker", false)] }
        let trending = await wait { sheet.items.count == 3 }
        check("the picker opens on the service's trending GIFs, in its order", trending && sheet.items.map(\.id) == ["t1", "t2", "t3"] && search.queries.first == "")
        check("the search field names the service, as KLIPY's terms ask", sheet.search.placeholderString == "Search KLIPY")
        let attribution = InteractionSelfChecks.descendants(sheet.panel.contentView ?? NSView(), of: NSTextField.self).contains { $0.stringValue == "Powered by KLIPY" }
        check("the picker credits the GIF service", attribution)
        let previewsPlaying = await wait {
            (0..<sheet.items.count).allSatisfy { (sheet.grid.item(at: IndexPath(item: $0, section: 0)) as? GIFPickerItem)?.hasPreview == true }
        }
        let firstCell = sheet.grid.item(at: IndexPath(item: 0, section: 0)) as? GIFPickerItem
        check("previews load from the service's media and play", previewsPlaying && firstCell?.isPlaying == GIFPickerSheet.animates)
        check("the first result is selected, so Return sends it", sheet.grid.selectionIndexPaths == [IndexPath(item: 0, section: 0)] && sheet.choose.isEnabled)

        sheet.search.stringValue = "party"
        sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.search))
        let searched = await wait { sheet.items.first?.id == "party-1" }
        check("typing searches the service", searched && search.queries.last == "party")
        let partyPreviews = await wait { sheet.items.allSatisfy { sheet.previews.contains($0.id) } }
        check("a new search keeps only its own compressed previews", partyPreviews && !sheet.previewData.isEmpty && Set(sheet.previewData.keys).isSubset(of: Set(sheet.items.map(\.id))))
        sheet.grid.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        sheet.accept()
        let queued = await wait { controller.gifSelectionTask == nil }
        let operations = try await session.store.operations()
        let gif = operations.first { $0.isGIF }
        check("choosing sends the GIF as a queued message in Raven's form", queued && gif?.html == #"<p><img alt="Party two" src="https://static.klipy.com/fixture/party-2.gif"></p>"#)
        check("the GIF carries the reply in progress, and the reply bar clears", gif?.replyTo == "question" && controller.replyTo == nil)
        let draft = try await session.store.draft(channelID: channel.id)
        check("the draft's text stays in the composer", draft?.html.contains("half written") == true && controller.composer.string.contains("half written"))
        controller.render(); await controller.renderTask?.value
        let echoed = await wait { session.animatedImages.contains(AnimatedImageKey.remote(URL(string: "https://static.klipy.com/fixture/party-2.gif")!)) }
        controller.render(); await controller.renderTask?.value
        var echoAttachment = false
        if let storage = controller.transcript.textStorage {
            storage.enumerateAttribute(.nevermoreAnimatedImage, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if (value as? String)?.contains("party-2.gif") == true { echoAttachment = true }
            }
        }
        check("the queued GIF shows in the transcript at once", echoed && echoAttachment)
        check("a GIF message carries no read-only formatting note", !controller.transcript.string.contains("Native formatting fallback"))

        // Taking a queued GIF back from the transcript cancels it while a
        // draft is in progress, and leaves the draft alone.
        if let gif {
            controller.ink.takeBack(gif.id)
            var remaining = try await session.store.operations()
            for _ in 0..<300 where remaining.contains(where: { $0.id == gif.id }) {
                try? await Task.sleep(for: .milliseconds(10)); remaining = try await session.store.operations()
            }
            let kept = try await session.store.draft(channelID: channel.id)
            check("taking a queued GIF back cancels it and leaves the draft in progress", !remaining.contains { $0.id == gif.id } && kept?.html.contains("half written") == true && controller.composer.string.contains("half written"))
        } else { check("a queued GIF can be taken back", false) }

        // Without a key, the picker says how to get one and searches nothing.
        let searchesBefore = search.queries.count
        controller.gifSourcesOverride = GIFPickerSheet.Sources(search: nil, provider: .giphy, media: media)
        controller.sendGIF(nil)
        let keyless = await wait { GIFPickerSheet.current != nil && parent.attachedSheet != nil }
        if keyless, let sheet = GIFPickerSheet.current {
            check("without a key the picker explains and offers GIF settings", sheet.status.stringValue == GIFSearchError.missingKey.localizedDescription && !sheet.openSettings.isHidden && sheet.search.placeholderString == "Search GIPHY" && search.queries.count == searchesBefore)
            sheet.cancel()
        } else { check("Send GIF opens the picker without a key", false) }
        let closed = await wait { parent.attachedSheet == nil && GIFPickerSheet.current == nil && controller.gifSelectionTask == nil }
        let leftover = try await session.store.operations()
        check("Cancel closes the picker and sends nothing", closed && leftover.isEmpty)

        // Editing a message is not the moment for a GIF.
        controller.editing = RavenMessage(raw: .object(["name": .string("question"), "channel_id": .string(channel.id)]))
        check("Send GIF is unavailable while editing a message", !controller.canSendGIF)
        controller.editing = nil
        return checks
    }
}

/// Three trending GIFs; any search answers with three "party" GIFs.
private final class PickerFixtureSearch: GIFSearching, @unchecked Sendable {
    let provider = GIFProvider.klipy
    private let lock = NSLock()
    private var recorded: [String] = []
    var queries: [String] { lock.withLock { recorded } }

    func page(query: String, cursor: Int?) async throws -> GIFPage {
        lock.withLock { recorded.append(query) }
        let prefix = query.isEmpty ? "t" : "party-"
        let titles = query.isEmpty ? ["Trending one", "Trending two", "Trending three"] : ["Party one", "Party two", "Party three"]
        let items = titles.enumerated().map { index, title in
            let name = query.isEmpty ? "t\(index + 1)" : "party-\(index + 1)"
            return GIFItem(id: "\(prefix)\(index + 1)", title: title,
                           preview: GIFRendition(url: URL(string: "https://static.klipy.com/fixture/\(name)-sm.gif")!, width: 80, height: 60),
                           message: GIFRendition(url: URL(string: "https://static.klipy.com/fixture/\(name).gif")!, width: 80, height: 60))
        }
        return GIFPage(items: items, next: nil)
    }
}

private actor PickerFixtureMedia: GIFMediaLoading {
    let data: Data
    init(data: Data) { self.data = data }
    func mediaData(for url: URL) async -> Data? { GIFMediaPolicy.isServiceMedia(url) ? data : nil }
}
