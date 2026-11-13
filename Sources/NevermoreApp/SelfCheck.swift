import AppKit
import RavenProtocol
import NevermoreCore

@MainActor enum SelfCheck {
    static func finishInputEvent(_ composer: ComposerView) async throws {
        composer.breakUndoCoalescing()
        // Synthetic input does not pass through NSApplication's event dispatch.
        // Let Cocoa end its automatic group; ending it manually leaves the
        // event checkpoint pending and can corrupt subsequent native edits.
        // A real app event advances Cocoa's checkpoint even when a synthetic
        // key closed a popover while the CI runner was in a tracking run loop.
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(event, atStart: false)
        }
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(5))
            if (composer.undoManager?.groupingLevel ?? 0) == 0 { return }
        }
        throw AppError.message("The synthetic input event did not finish its native undo group.")
    }
    static func run(_ app: AppDelegate) async -> Int {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) { if !value { failures.append(label) }; print("\(value ? "PASS" : "FAIL") \(label)"); fflush(nil) }
        let expectedCoreResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true).resolvingSymlinksInPath()
        let resolvedCoreBundle = StatusLocalization.resourceBundleURL.resolvingSymlinksInPath()
        check(Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.resourceURL?.resolvingSymlinksInPath() == expectedCoreResources && resolvedCoreBundle.deletingLastPathComponent() == expectedCoreResources && resolvedCoreBundle.lastPathComponent == "Nevermore_NevermoreCore.bundle", "Core localization resolves inside the packaged app Resources directory")
        guard let first = app.windows.first, let session = first.session, let channel = first.channel else { print("FAIL demo window missing"); return 1 }
        await first.loadTask?.value
        await first.renderTask?.value
        first.window?.contentView?.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.arguments.contains("--composer-self-check") {
            for (label, result) in ComposerSizingSelfChecks.run(app: app) { check(result, label) }
            for (label, result) in await composerFormattingChecks(in: first) { check(result, label) }
            for (label, result) in await InlineComposerSelfChecks.run(in: first) { check(result, label) }
            print("Native composer self-check: \(failures.isEmpty ? "PASS" : "FAIL") (\(failures.count) failures)")
            return failures.isEmpty ? 0 : 1
        }
        func fitsPane(_ text: NSTextView, _ scroll: NSScrollView) -> Bool { scroll.contentSize.width > 0 && abs(text.frame.width - scroll.contentSize.width) < 1 }
        check(fitsPane(first.transcript, first.transcriptScroll), "transcript document width matches its visible pane")
        check(fitsPane(first.composer, first.composerScroll), "composer document width matches its visible pane")
        first.window?.toolbar?.validateVisibleItems()
        let sidebarItem = first.window?.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar }
        check(sidebarItem?.isEnabled == true && first.window?.contentViewController === first.splitController && first.sidebarSplitItem.behavior == .sidebar, "native sidebar toolbar command is enabled for this split view")
        check(!ConversationToolbar.defaultItems.contains(.nevermoreNavigation) && ConversationToolbar.allowedItems.contains(.nevermoreNavigation), "Back/Forward is an optional toolbar item, not a default one")
        if let toolbar = first.window?.toolbar, let group = first.toolbar(toolbar, itemForItemIdentifier: .nevermoreNavigation, willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup {
            // AppKit's own item validation, not a direct call into the window:
            // the earlier segmented group validated both chevrons as enabled.
            func enabledDirections() -> [Bool] { group.validate(); return group.subitems.map(\.isEnabled) }
            let saved = first.navigation
            first.navigation = NavigationHistory()
            first.navigation.visit(ConversationLocation(channelID: "self-check-a")); first.navigation.visit(ConversationLocation(channelID: "self-check-b"))
            let atNewest = enabledDirections()
            _ = first.navigation.back()
            let afterBack = enabledDirections()
            first.navigation = saved
            check(atNewest == [true, false] && afterBack == [false, true], "Back/Forward toolbar items dim the direction with no history")
        } else { check(false, "Back/Forward toolbar item is a two-item group") }
        let visibleWidth = first.transcriptScroll.contentSize.width
        first.toggleSidebar(nil); first.window?.contentView?.layoutSubtreeIfNeeded()
        check(first.sidebarSplitItem.isCollapsed && first.transcriptScroll.contentSize.width > visibleWidth, "hiding the sidebar returns its width to the conversation")
        first.toggleSidebar(nil); first.window?.contentView?.layoutSubtreeIfNeeded()
        check(!first.sidebarSplitItem.isCollapsed && fitsPane(first.transcript, first.transcriptScroll) && fitsPane(first.composer, first.composerScroll), "restoring the sidebar preserves native text wrapping")
        if let window = first.window {
            let original = window.frame
            var narrow = original; narrow.size.width = 700
            window.setFrame(narrow, display: true); window.contentView?.layoutSubtreeIfNeeded()
            check(fitsPane(first.transcript, first.transcriptScroll), "transcript wrapping follows a narrow window resize")
            check(fitsPane(first.composer, first.composerScroll), "composer wrapping follows a narrow window resize")
            window.setFrame(original, display: true); window.contentView?.layoutSubtreeIfNeeded()
        }
        check(first.messageRanges.count >= 4, "native transcript renders multiple messages")
        first.transcript.selectAll(nil)
        check(first.transcript.selectedRange().length == first.transcript.string.utf16.count && first.transcript.selectedRange().length > 100, "Select All spans message boundaries")
        check(first.transcript.isSelectable && !first.transcript.isEditable, "transcript uses native read-only text selection")
        check(first.composer.allowsUndo, "composer has native Undo")
        check(NSApp.mainMenu?.items.count ?? 0 >= 8, "standard application menus installed")
        app.open(session: session, channel: channel)
        guard let second = app.windows.last else { print("FAIL second window missing"); return 1 }
        check(second !== first && second.session === first.session, "two windows share one account session")
        var sends = 0
        second.composer.onSend = { sends += 1 }
        second.composer.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: second.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { second.composer.keyDown(with: event) }
        check(sends == 0, "Return during marked text does not send")
        second.composer.unmarkText()
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: second.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { second.composer.keyDown(with: event) }
        check(sends == 1, "Command-Return sends committed text")
        check(session.demo, "demo is explicitly isolated from network sends")
        do {
            let doc = try RichTextCodec.parse("<p>Hello <span data-type=\"userMention\" data-id=\"alex@example.com\">Alex</span></p>")
            let attributed = NativeRichText.attributedString(document: doc)
            let html = RichTextCodec.html(try NativeRichText.document(from: attributed))
            check(html.contains("alex@example.com") && html.contains("userMention"), "native composer preserves mention identity")
        } catch { check(false, "native rich-text adapter round-trip: \(error.localizedDescription)") }
        do {
            let doc = try RichTextCodec.parse("<p>Hello world</p>")
            let edited = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            edited.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 6, length: 5))
            let html = RichTextCodec.html(try NativeRichText.document(from: edited))
            check(html.contains("<strong>world</strong>"), "format-only edits survive unchanged plain text")
            let emoji = try RichTextCodec.parse("<p>Hi <img data-type=\"customEmoji\" data-id=\"parrot\" alt=\":parrot:\" src=\"/files/parrot.png\"> there</p>")
            let changed = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: emoji))
            changed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 4, length: 2))
            changed.append(NSAttributedString(string: "!"))
            let encoded = RichTextCodec.html(try NativeRichText.document(from: changed))
            check(encoded.components(separatedBy: "customEmoji").count == 2, "font-run splits do not duplicate a custom emoji")
            let quote = try RichTextCodec.parse("<blockquote><p>One</p></blockquote>")
            let quoted = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: quote))
            quoted.append(NSAttributedString(string: "\nTwo", attributes: quoted.attributes(at: 0, effectiveRange: nil)))
            check(RichTextCodec.plainText(try NativeRichText.document(from: quoted)).contains("Two"), "new quoted lines retain their first characters")
        } catch { check(false, "rich editor regression: \(error.localizedDescription)") }
        do {
            let stress = RavenChannel(raw: .object(["name": .string("stress"), "channel_name": .string("10,000-message fixture")]))
            let rows = (0..<10_000).map { index in RavenMessage(raw: .object(["name": .string(String(format: "stress-%05d", index)), "channel_id": .string(stress.id), "owner": .string("fixture@example.com"), "creation": .string(String(format: "2026-11-07 12:%02d:%02d.%06d", index / 3600, (index / 60) % 60, index)), "text": .string("<p>Fixture message \(index)</p>"), "message_type": .string("Text")])) }
            try await session.store.cacheMessages(rows)
            let began = Date()
            app.open(session: session, channel: stress)
            if let stressWindow = app.windows.last {
                await stressWindow.loadTask?.value; await stressWindow.renderTask?.value
                check(stressWindow.messages.count == 500, "10,000-message fixture keeps a bounded native working set")
                check(stressWindow.transcript.layoutManager?.textContainers.count == 1, "transcript uses one text container rather than 10,000 message views")
                print("MEASURE synthetic cached window render: \(Int(Date().timeIntervalSince(began) * 1000)) ms (\(configuration), one sample)")
            }
        } catch { check(false, "large-history fixture: \(error.localizedDescription)") }
        do {
            session.userNames["alex@example.com"] = "Alex"
            second.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); second.window?.makeFirstResponder(second.composer)
            await second.saveTask?.value
            for _ in 0..<100 { if second.window?.isKeyWindow == true { break }; try await Task.sleep(for: .milliseconds(10)) }
            second.composer.selectAll(nil)
            second.composer.insertText("@Al", replacementRange: NSRange(location: NSNotFound, length: 0))
            let beforeCompletion = second.composer.string
            try await finishInputEvent(second.composer)
            second.updateCompletions()
            if !second.mentionPopover.popover.isShown { print("DIAGNOSTIC completion key=\(second.window?.isKeyWindow == true) focus=\(second.window?.firstResponder === second.composer) marked=\(second.composer.hasMarkedText()) query=\(MentionCompletion.query(in: second.composer.string, selection: second.composer.selectedRange()) != nil)") }
            check(second.mentionPopover.popover.isShown && second.mentionPopover.candidates.first?.serverID == "alex@example.com", "native mention suggestions keep keyboard focus and server identity")
            await second.saveTask?.value
            try await Task.sleep(for: .milliseconds(20))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: second.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { second.composer.keyDown(with: event) }
            let completedDraft = try second.currentDraft()
            check(sends == 1 && completedDraft.html.contains("data-id=\"alex@example.com\""), "Return accepts a suggestion without sending a message")
            await second.saveTask?.value
            try await Task.sleep(for: .milliseconds(20))
            try await finishInputEvent(second.composer)
            second.composer.undoManager?.undo()
            if second.composer.string != beforeCompletion { print("DIAGNOSTIC mention undo text=\(second.composer.string.debugDescription) html=\((try? second.currentDraft().html) ?? "error") grouping=\(second.composer.undoManager?.groupingLevel ?? -1)") }
            check(second.composer.string == beforeCompletion, "native Undo restores the typed mention query")
            try await finishInputEvent(second.composer)
            second.composer.setSelectedRange(NSRange(location: second.composer.string.utf16.count, length: 0))
            second.window?.makeFirstResponder(second.composer); second.updateCompletions()
            let openForCommand = second.mentionPopover.popover.isShown
            if let event = InteractionSelfChecks.key(36, window: second.window!, modifiers: .command) { second.composer.keyDown(with: event) }
            check(openForCommand && sends == 2 && !second.mentionPopover.popover.isShown, "Command-Return keeps its send meaning while suggestions are open")
            try await finishInputEvent(second.composer)
            second.updateCompletions()
            let beforeNewline = second.composer.string
            let openForNewline = second.mentionPopover.popover.isShown
            if let event = InteractionSelfChecks.key(36, window: second.window!, modifiers: .shift) { second.composer.keyDown(with: event) }
            check(openForNewline && sends == 2 && second.composer.string.count > beforeNewline.count, "Shift-Return inserts a line break while suggestions are open")
            second.mentionPopover.close()
            guard let parent = first.messages.first else { throw AppError.message("Thread parent fixture missing") }
            let reply = RavenMessage(raw: .object(["name": .string("inspector-reply"), "channel_id": .string(parent.id), "owner": .string("alex@example.com"), "creation": .string("2026-11-07 13:00:00.000001"), "text": .string("<p>Thread inspector fixture</p>"), "message_type": .string("Text")]))
            try await session.store.cacheMessages([reply])
            if let window = first.window { var frame = window.frame; frame.size.width = 1080; window.setFrame(frame, display: true) }
            first.showThreadInspector(root: parent)
            await first.threadInspector?.waitUntilLoaded()
            check(first.threadInspector?.rows.contains(where: { $0.id == reply.id }) == true && session.interests.values.contains(parent.id), "thread inspector loads replies through the shared account session")
            first.window?.contentView?.layoutSubtreeIfNeeded()
            check(first.threadInspector.map { fitsPane($0.transcript, $0.scroll) } == true, "thread replies wrap within the inspector pane")
            let inspector = first.threadInspector
            first.closeThreadInspector()
            check(!session.interests.values.contains(parent.id) && inspector?.context.stringValue == "" && inspector?.transcript.string == "", "closing the inspector releases room interest and private text")
            app.open(session: session, channel: RavenChannel(raw: .object(["name": .string(parent.id), "channel_name": .string("Thread fixture"), "is_thread": .bool(true), "parent_channel_id": .string(parent.channelID)])))
            if let threadWindow = app.windows.last {
                await threadWindow.loadTask?.value; await threadWindow.threadContextTask?.value; await threadWindow.renderTask?.value
                check(threadWindow.threadRoot?.id == parent.id && threadWindow.currentLocation()?.threadParentChannelID == parent.channelID, "thread windows retain authorized root context and a restorable parent route")
                session.revokedChannels.insert(parent.channelID); threadWindow.render()
                check(threadWindow.threadRoot == nil && threadWindow.transcript.string.isEmpty, "parent permission revocation clears private thread-window content")
                session.revokedChannels.remove(parent.channelID); threadWindow.close()
            }
        } catch { check(false, "completion/thread integration: \(error.localizedDescription)") }
        do { for (label, result) in try RichTextSelfChecks.run() { check(result, label) } }
        catch { check(false, "rich text checks: \(error.localizedDescription)") }
        do {
            for (label, result) in try await ComposerTypingSelfChecks.run() { check(result, label) }
            for (label, result) in try await ComposerTypingSelfChecks.runKeyEvents(window: second) { check(result, label) }
            for (label, result) in try await ComposerTypingSelfChecks.runLinkPreview(window: second) { check(result, label) }
        } catch { check(false, "composer typing checks: \(error.localizedDescription)") }
        do { for (label, result) in try await InteractionSelfChecks.run(window: second, session: session) { check(result, label) } }
        catch { check(false, "native interaction checks: \(error.localizedDescription)") }
        do { for (label, result) in try await CodeReadingSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "code reader/privacy checks: \(error.localizedDescription)") }
        do { for (label, result) in try await PromisedFileSelfChecks.run() { check(result, label) } }
        catch { check(false, "promised-file checks: \(error.localizedDescription)") }
        do { for (label, result) in try await PromisedFileBoundarySelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "promised-file boundary checks: \(error.localizedDescription)") }
        for (label, result) in PerformanceButtonActionSelfChecks.run() { check(result, label) }
        do { for (label, result) in try await CollectionAttachmentSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "file search attachment checks: \(error.localizedDescription)") }
        do { for (label, result) in try await CollectionInteractionSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "collection keyboard checks: \(error.localizedDescription)") }
        do { for (label, result) in try await UnreadAffordanceSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "unread affordance checks: \(error.localizedDescription)") }
        do { for (label, result) in try await UndoSendSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "Undo Send self-checks: \(error.localizedDescription)") }
        do { for (label, result) in try await ReactionUndoSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "Reaction Undo self-checks: \(error.localizedDescription)") }
        do { for (label, result) in try await DelightSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "raven and sticker checks: \(error.localizedDescription)") }
        do { for (label, result) in try await TranscriptLayoutSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "transcript layout checks: \(error.localizedDescription)") }
        do { for (label, result) in try await TranscriptViewportSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "transcript viewport checks: \(error.localizedDescription)") }
        do { for (label, result) in try await TranscriptPlacementSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "transcript placement checks: \(error.localizedDescription)") }
        do { for (label, result) in try await AccessibilitySelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "native message accessibility checks: \(error.localizedDescription)") }
        do { for (label, result) in try await StatusAnnouncementSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "native status announcement checks: \(error.localizedDescription)") }
        if let resources = Bundle.main.resourceURL, Bundle.main.bundleIdentifier != nil {
            let localized = Bundle(url: resources.appendingPathComponent("Nevermore_NevermoreCore.bundle"))
            check(localized?.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil && localized?.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "de") != nil, "packaged app includes the localized Core resources")
            check(StatusLocalization.text(.needsReview, locale: Locale(identifier: "de")) == "Überprüfung erforderlich" && StatusLocalization.text(.accountAttention, locale: Locale(identifier: "de")) == "This account needs attention. Review its status or reconnect from account settings.", "packaged localization selects a language and falls back to English")
        } else { print("SKIP packaged localization: run the assembled app") }
        do { for (label, result) in try await LifecycleSelfChecks.run(app: app, owner: first) { check(result, label) } }
        catch { check(false, "draft lifecycle checks: \(error.localizedDescription)") }
        do { for (label, result) in try await ReconciliationSelfChecks.run() { check(result, label) } }
        catch { check(false, "reconciliation checks: \(error.localizedDescription)") }
        for (label, result) in ClipboardAttachmentSelfChecks.run() { check(result, label) }
        if let index = CommandLine.arguments.firstIndex(of: "--attachment-fixture-origin") {
            do {
                guard CommandLine.arguments.indices.contains(index + 1) else { throw AppError.message("Missing local attachment fixture origin.") }
                for (label, result) in try await AttachmentSelfChecks.run(origin: CommandLine.arguments[index + 1]) { check(result, label) }
            } catch { check(false, "attachment fixture: \(error.localizedDescription)") }
        }
        for (label, result) in RavenPortraitSelfChecks.run() { check(result, label) }
        do { for (label, result) in try ChannelAvatarSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "channel avatar fixture: \(error)") }
        do { for (label, result) in try SidebarAvatarSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "sidebar profile photos: \(error.localizedDescription)") }
        for (label, result) in ConversationGeometrySelfChecks.run() { check(result, label) }
        for (label, result) in ComposerSizingSelfChecks.run(app: app) { check(result, label) }
        for (label, result) in await composerFormattingChecks(in: first) { check(result, label) }
        for (label, result) in await InlineComposerSelfChecks.run(in: first) { check(result, label) }
        do { for (label, result) in try await ConversationDropSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "conversation file drops: \(error.localizedDescription)") }
        do { for (label, result) in try await UpdateSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "native update checks: \(error.localizedDescription)") }
        do { for (label, result) in try await NativeShellSelfChecks.run(app: app) { check(result, label) } }
        catch { check(false, "native shell: \(error.localizedDescription)") }
        do { for (label, result) in try await PollSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "poll checks: \(error.localizedDescription)") }
        if let index = CommandLine.arguments.firstIndex(of: "--poll-fixture-origin") {
            do {
                guard CommandLine.arguments.indices.contains(index + 1) else { throw AppError.message("Missing local poll fixture origin.") }
                for (label, result) in try await PollNetworkSelfChecks.run(app: app, origin: CommandLine.arguments[index + 1]) { check(result, label) }
            } catch { check(false, "poll RPC fixture: \(error.localizedDescription)") }
        }
        do { for (label, result) in try await EmojiSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "emoji checks: \(error.localizedDescription)") }
        do { for (label, result) in try await QuickReactionSelfChecks.run(owner: first) { check(result, label) } }
        catch { check(false, "quick reaction checks: \(error.localizedDescription)") }
        if let index = CommandLine.arguments.firstIndex(of: "--reaction-fixture-origin") {
            do {
                guard CommandLine.arguments.indices.contains(index + 1) else { throw AppError.message("Missing local reaction fixture origin.") }
                for (label, result) in try await QuickReactionSelfChecks.runNetwork(app: app, origin: CommandLine.arguments[index + 1]) { check(result, label) }
            } catch { check(false, "reaction RPC fixture: \(error.localizedDescription)") }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--avatar-fixture-origin") {
            do {
                guard CommandLine.arguments.indices.contains(index + 1) else { throw AppError.message("Missing local avatar fixture origin.") }
                for (label, result) in try await AvatarSelfChecks.runNetwork(app: app, origin: CommandLine.arguments[index + 1]) { check(result, label) }
            } catch { check(false, "avatar fixture: \(error.localizedDescription)") }
        }
        do { for (label, result) in try await BrowserAuthenticationSelfChecks.run() { check(result, label) } }
        catch { check(false, "browser authentication callback checks: \(error.localizedDescription)") }
        for (label, result) in OnboardingSelfChecks.run(app: app) { check(result, label) }
        for (label, result) in await ThemeSelfChecks.run(app: app, owner: first) { check(result, label) }
        let collection = CollectionWindow(owner: first, title: "Privacy fixture", records: [.object(["channel_id": .string("revoked"), "content": .string("Private fixture")]), .object(["channel_id": .string(channel.id), "content": .string("Allowed fixture")])], kind: .search)
        first.collectionWindows.append(collection)
        session.revokedChannels.insert("revoked"); collection.restrictRevoked()
        check(collection.records.count == 1, "collections remove known revoked conversation content")
        first.use(nil)
        check(collection.records.isEmpty && first.transcript.string.isEmpty && first.composer.string.isEmpty, "account switching clears private collection and conversation views")
        for window in Array(app.windows) { await window.saveTask?.value; window.close() }
        print("Native self-check: \(failures.isEmpty ? "PASS" : "FAIL") (\(failures.count) failures)")
        return failures.isEmpty ? 0 : 1
    }
}
