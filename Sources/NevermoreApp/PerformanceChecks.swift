import AppKit
import Darwin
import NevermoreCore
import RavenProtocol

/// Explicit demo-only measurements. Never accesses account registrations,
/// credentials, updater, notifications, login items or a live Raven endpoint.
@MainActor enum PerformanceChecks {
    static var mainEnteredAt = 0.0
    private static func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) { print(line); fflush(nil) }
    }
    private static func progress(_ phase: String) { emit(["event": "progress", "phase": phase]) }
    private static func milliseconds(since start: Double) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    private static func summary(_ samples: [Double]) throws -> [String: Any] {
        guard let result = PerformanceMetrics.summarize(samples) else { throw AppError.message("Invalid performance samples.") }
        return ["unit": "milliseconds", "count": result.count, "samples": samples, "p50": result.p50, "p95": result.p95, "minimum": result.minimum, "maximum": result.maximum]
    }
    private struct Resources {
        let cpuSeconds: Double
        let residentBytes: UInt64?
        let footprintBytes: UInt64?
        let taskInfoStatus: kern_return_t
        var json: [String: Any] { ["cpu_seconds": cpuSeconds, "resident_bytes": residentBytes.map { $0 as Any } ?? NSNull(), "physical_footprint_bytes": footprintBytes.map { $0 as Any } ?? NSNull(), "task_info_status": taskInfoStatus] }
    }
    private static func resources() throws -> Resources {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw AppError.message("Could not read process CPU usage.") }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Resources(cpuSeconds: cpu, residentBytes: status == KERN_SUCCESS ? info.resident_size : nil, footprintBytes: status == KERN_SUCCESS ? info.phys_footprint : nil, taskInfoStatus: status)
    }
    private static func layOut(_ controller: ConversationWindow) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if let container = controller.transcript.textContainer { controller.transcript.layoutManager?.ensureLayout(for: container) }
        controller.window?.displayIfNeeded()
    }
    private static func settle(_ controller: ConversationWindow) async {
        await controller.loadTask?.value
        await controller.renderTask?.value
        layOut(controller)
    }
    private static func fixtureDirectory(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(PerformanceMetrics.fixtureDirectoryName(for: id), isDirectory: true)
    }
    /// Resolves only a canonical UUID beneath this executable's Foundation
    /// temporary directory, never a path supplied by a child process.
    static func cleanupFixture(_ id: UUID) throws {
        let directory = fixtureDirectory(id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private static func channels() -> [RavenChannel] {
        ["large", "second"].map { RavenChannel(raw: .object(["name": .string("performance-\($0)"), "channel_name": .string("Performance \($0)"), "workspace": .string("Fixture")])) }
    }
    private static func populate(_ store: AccountStore, channels: [RavenChannel]) async throws {
        try await store.cacheChannels(channels)
        let bodies = ["<p>Plain fixture message with emoji 👩🏽‍💻 and العربية 日本語.</p>", "<p><strong>Bold</strong> <a href=\"https://example.invalid\">inert fixture link</a> <span data-spoiler>hidden fixture</span></p>", "<blockquote><p>Quote fixture</p></blockquote><ul><li>one</li><li>two</li></ul>", "<pre><code>let fixture = 1\nprint(fixture)</code></pre>", "<table><tr><th>A</th><th>B</th></tr><tr><td>one</td><td>two</td></tr></table>", "<p><img data-type=\"customEmoji\" src=\"/files/fixture.png\" alt=\":fixture:\"></p>"]
        for (channelIndex, channel) in channels.enumerated() {
            let total = channelIndex == 0 ? 10_000 : 200
            // One fixed-size batch permits the real store's normal 1,000-row
            // retention policy to trim the synthetic 10,000-row history.
            // Typed field construction: the Xcode 26 type checker times out
            // on this as one literal expression.
            let rows: [RavenMessage] = (0..<total).map { (index: Int) -> RavenMessage in
                let name: String = String(format: "performance-%d-%05d", channelIndex, index)
                let creation: String = String(format: "2026-11-08 %02d:%02d:%02d.000000", 12 + index / 3600, (index / 60) % 60, index % 60)
                var fields: [String: JSONValue] = [:]
                fields["name"] = .string(name)
                fields["channel_id"] = .string(channel.id)
                fields["owner"] = .string("performance-fixture@example.invalid")
                fields["creation"] = .string(creation)
                fields["text"] = .string(bodies[index % bodies.count])
                fields["message_type"] = .string("Text")
                return RavenMessage(raw: .object(fields))
            }
            try await store.cacheMessages(rows)
        }
    }
    static func seedFixture(_ id: UUID) async throws {
        let directory = fixtureDirectory(id)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw AppError.message("Seed fixture already exists.") }
        let began = ProcessInfo.processInfo.systemUptime
        do {
            let store = try AccountStore(directory: directory)
            try await populate(store, channels: channels())
            emit(["event": "seed_complete", "milliseconds": milliseconds(since: began)])
        } catch { try? cleanupFixture(id); throw error }
    }
    private struct FeedbackSamples {
        var actionDelivery: [Double] = []
        var clickActionObservation: [Double] = []
        var clickTotal: [Double] = []
        var preAction: [Double] = []
    }
    private enum FeedbackDispatch { case syntheticClick, nativeAction }
    private static func measureSendFeedback(_ controller: ConversationWindow, dispatch: FeedbackDispatch) async throws -> PerformanceMetrics.FeedbackSample {
        let action = PerformanceButtonAction(button: controller.sendButton)
        defer { action.restore() }
        let began = ProcessInfo.processInfo.systemUptime
        switch dispatch {
        case .syntheticClick: controller.sendButton.performClick(nil)
        case .nativeAction:
            guard let selector = controller.sendButton.action,
                  NSApp.sendAction(selector, to: controller.sendButton.target, from: controller.sendButton) else { throw AppError.message("Native Send action dispatch failed.") }
        }
        guard action.forwarded, action.forwardCount == 1, let delivered = action.deliveredAt else { throw AppError.message("The benchmark did not deliver exactly one production Send action.") }
        let deadline = began + 5
        while !(controller.composer.string.isEmpty && !controller.isAcceptingSend && controller.composer.isEditable && controller.sendButton.isEnabled) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("Timed out waiting for durable send feedback; never replayed.") }
            try await Task.sleep(for: .milliseconds(1))
        }
        layOut(controller)
        guard let sample = PerformanceMetrics.feedbackSample(clickStarted: began, actionDelivered: delivered, observed: ProcessInfo.processInfo.systemUptime), action.forwardCount == 1 else { throw AppError.message("Invalid production Send timing boundaries.") }
        return sample
    }
    private static func sendFeedback(_ app: AppDelegate, origin: URL, directory: URL) async throws -> FeedbackSamples {
        let account = Account(id: UUID(), origin: origin, user: "performance-fixture@example.invalid", siteName: "Loopback fixture", clientID: "performance-loopback", displayName: "Loopback fixture")
        let session = try AccountSession(account: account, directory: directory.appendingPathComponent("Feedback"), authentication: .loopbackFixture)
        let channel = RavenChannel(raw: .object(["name": .string("performance-feedback"), "channel_name": .string("Performance feedback"), "is_thread": .number(0), "is_archived": .number(0)]))
        session.channels = [channel]
        app.sessions.append(session)
        app.open(session: session, channel: channel)
        guard let controller = app.windows.last, controller.session === session else { throw AppError.message("Feedback window missing.") }
        func dispose() {
            controller.close(); session.stop(); app.sessions.removeAll { $0 === session }
        }
        do {
            await settle(controller)
            var samples = FeedbackSamples()
            for index in 0..<10 {
                guard controller.composer.isEditable, !controller.isAcceptingSend else { throw AppError.message("Feedback composer unavailable.") }
                controller.composer.insertText("Feedback fixture \(index)", replacementRange: NSRange(location: 0, length: controller.composer.attributedString().length))
                controller.updateContext()
                guard controller.sendButton.isEnabled else { throw AppError.message("Feedback Send unavailable.") }
                let dispatch: FeedbackDispatch = index < 5 ? .syntheticClick : .nativeAction
                let sample = try await measureSendFeedback(controller, dispatch: dispatch)
                if index < 5 {
                    samples.clickActionObservation.append(sample.actionToFeedbackMS)
                    samples.clickTotal.append(sample.clickToFeedbackMS)
                    samples.preAction.append(sample.preActionMS)
                } else {
                    samples.actionDelivery.append(sample.actionToFeedbackMS)
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                // Wait for the single synthetic POST acknowledgement before the
                // next click. A timeout aborts, never retries an uncertain send.
                while true {
                    let operations = try await session.store.operations()
                    if operations.isEmpty && !session.flushing { break }
                    guard operations.allSatisfy({ $0.error == nil }), ProcessInfo.processInfo.systemUptime < deadline else { throw AppError.message("Loopback acknowledgement failed; never replayed.") }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            dispose(); await session.client.invalidate()
            return samples
        } catch { dispose(); await session.client.invalidate(); throw error }
    }
    static func run(_ app: AppDelegate) async {
        let options: PerformanceMetrics.Options
        do { options = try PerformanceMetrics.Options(arguments: CommandLine.arguments) }
        catch { emit(["event": "error", "message": "Invalid performance arguments."]); exit(2) }
        let directory = fixtureDirectory(options.fixtureID)
        var code: Int32 = 0
        var report: [String: Any]?
        do {
            progress(options.reuseFixture ? "open_cached_fixture" : "seed_fixture")
            let account = Account(id: UUID(), origin: URL(string: "https://demo.invalid")!, user: "performance-fixture@example.invalid", siteName: "Performance fixture", clientID: "demo", displayName: "Performance fixture")
            let session = try AccountSession(account: account, directory: directory, demo: true)
            emit(["event": "fixture_directory", "path": directory.path])
            app.sessions.append(session)
            let channels = channels()
            session.channels = channels; session.userNames = ["performance-fixture@example.invalid": "Fixture author"]
            if !options.reuseFixture { try await populate(session.store, channels: channels) }
            app.makeMenus(); app.newWindow(nil)
            guard let controller = app.windows.first else { throw AppError.message("Performance window missing.") }
            controller.select(channels[0], record: false); await settle(controller)
            guard controller.window?.isVisible == true, controller.composer.isEditable, !controller.messages.isEmpty else { throw AppError.message("Demo content is not interactive.") }
            let launchMS = milliseconds(since: mainEnteredAt)
            emit(["event": "first_interactive", "since_main_ms": launchMS, "cached_fixture": options.reuseFixture])
            let cachedCount = try await session.store.messages(channelID: channels[0].id, limit: 10_000).count
            guard cachedCount == 1000, controller.messages.count == 500,
                  try await session.store.messages(channelID: channels[1].id, limit: 10000).count == 200 else { throw AppError.message("Fixture retention bounds were not met.") }
            if options.cachedLaunchOnly {
                #if DEBUG
                let configuration = "Debug"
                #else
                let configuration = "Release"
                #endif
                controller.close(); session.stop(); app.sessions.removeAll()
                emit(["event": "result", "configuration": configuration, "cached_launch_since_main_ms": launchMS, "cached_fixture": true])
                exit(0)
            }
            progress("cached_switches")
            var switches: [Double] = []
            for index in 0..<options.iterations {
                let began = ProcessInfo.processInfo.systemUptime
                controller.select(channels[(index + 1) % 2], record: false); await settle(controller)
                switches.append(milliseconds(since: began))
            }
            controller.select(channels[0], record: false); await settle(controller)
            progress("scroll_steps")
            var scrolls: [Double] = []
            for index in 0..<20 {
                let began = ProcessInfo.processInfo.systemUptime
                let clip = controller.transcriptScroll.contentView
                let extent = max(0, controller.transcript.bounds.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: extent * CGFloat(index) / 19))
                controller.transcriptScroll.reflectScrolledClipView(clip)
                layOut(controller)
                scrolls.append(milliseconds(since: began))
                await Task.yield()
            }
            progress("durable_enqueue")
            var enqueues: [Double] = []
            for index in 0..<options.iterations {
                let draft = Draft(channelID: channels[1].id, html: "<p>Durable fixture \(index)</p>")
                try await session.store.saveDraft(draft)
                let began = ProcessInfo.processInfo.systemUptime
                _ = try await session.store.acceptDraft(channelID: draft.channelID, expected: draft)
                enqueues.append(milliseconds(since: began))
            }
            var feedback = FeedbackSamples()
            if let origin = options.loopbackOrigin {
                progress("production_send_feedback")
                feedback = try await sendFeedback(app, origin: origin, directory: directory)
                controller.window?.makeKeyAndOrderFront(nil)
                guard app.sessions.count == 1, app.windows.count == 1 else { throw AppError.message("Feedback fixture did not detach before idle.") }
            }
            // Permit pending AppKit/store work to settle without blocking its run loop.
            progress("settling")
            try await Task.sleep(for: .seconds(2))
            let before = try resources(), idleBegan = ProcessInfo.processInfo.systemUptime
            progress("idle_\(options.idleSeconds)_seconds")
            try await Task.sleep(for: .seconds(options.idleSeconds))
            let elapsed = ProcessInfo.processInfo.systemUptime - idleBegan, after = try resources()
            let cpuPercent = elapsed > 0 ? max(0, after.cpuSeconds - before.cpuSeconds) / elapsed * 100 : 0
            let switchSummary = try summary(switches)
            #if DEBUG
            let configuration = "Debug"
            #else
            let configuration = "Release"
            #endif
            let footprint = after.footprintBytes
            #if arch(arm64)
            let architecture = "arm64"
            #elseif arch(x86_64)
            let architecture = "x86_64"
            #else
            let architecture = "unknown"
            #endif
            report = ["schema": 1, "event": "result", "configuration": configuration, "compiled_architecture": architecture, "pid": ProcessInfo.processInfo.processIdentifier, "fixture": ["seeded_messages": 10200, "large_channel_seeded": 10000, "large_channel_cached": cachedCount, "large_channel_visible": controller.messages.count, "mixed_media": "native tables/code/marks/emoji shortcodes; no downloaded media"], "demo_fixture_launch_since_main_ms": launchMS, "cached_switch": switchSummary, "scroll_step_layout_display": try summary(scrolls), "durable_enqueue_commit": try summary(enqueues), "queued_send_UI_feedback": feedback.actionDelivery.isEmpty ? NSNull() : try summary(feedback.actionDelivery), "queued_send_perform_click_action_observation": feedback.clickActionObservation.isEmpty ? NSNull() : try summary(feedback.clickActionObservation), "queued_send_perform_click_total": feedback.clickTotal.isEmpty ? NSNull() : try summary(feedback.clickTotal), "synthetic_button_pre_action": feedback.preAction.isEmpty ? NSNull() : try summary(feedback.preAction), "resources_before_idle": before.json, "resources_after_idle": after.json, "idle": ["requested_seconds": options.idleSeconds, "measured_seconds": elapsed, "cpu_percent_one_core": cpuPercent], "targets": ["cached_switch_p95_under_100_ms": (switchSummary["p95"] as? Double ?? .infinity) < 100 ? "pass" : "fail", "demo_footprint_under_200_MB": footprint.map { $0 < 200_000_000 ? "pass" : "fail" } ?? "unmeasured", "quiet_5min_cpu_below_0_5_percent": options.idleSeconds >= 300 ? (cpuPercent < 0.5 ? "pass" : "fail") : "unmeasured", "cached_relaunch_under_2_seconds": "unmeasured", "queued_send_UI_feedback_under_100_ms": feedback.actionDelivery.isEmpty ? "unmeasured" : ((PerformanceMetrics.summarize(feedback.actionDelivery)?.p95 ?? .infinity) < 100 ? "pass" : "fail"), "scroll_60Hz": "unmeasured", "energy_and_network_activity": "unmeasured"], "limits": [options.reuseFixture ? "This run reopens a preseeded fixture; driver reports independent cached launch probes." : "Fresh demo fixture startup includes seeding, not persisted cached relaunch.", "Switch timings await actual cached load/render/layout; no live server or downloaded images.", "Scroll steps measure synchronous layout/display CPU time, not presented frames or 60 Hz.", "Durable enqueue measures acceptDraft transaction completion. Separate UI feedback samples use the production Send button and credential-free loopback transport; they include observable cleared/enabled composer and native display.", "Queued-send UI target uses five native NSApp.sendAction dispatches, timed from forwarded production action delivery to observed cleared/enabled composer plus display. Five separate performClick totals/action-observation/pre-action series preserve synthetic delays before or after callback dispatch; no guessed delay is subtracted.", "A benchmark-only forwarding target timestamps immediately before forwarding the original target/action exactly once, and restores both in defer. Physical input/event-delivery latency is not measured.", "Loopback acknowledgement is bounded and never replayed by the harness; no real account or server is used.", "Settled local demo resource samples do not prove real-server, multi-account, energy or memory-growth budgets.", "Launch excludes work before Swift main; driver separately measures spawn-to-interactive.", "Reference hardware and production Release configuration require operator confirmation."]]
        } catch {
            code = 1; emit(["event": "error", "message": "Performance fixture failed: \(error.localizedDescription)"])
        }
        for controller in Array(app.windows) { controller.loadTask?.cancel(); controller.renderTask?.cancel(); controller.saveTask?.cancel(); controller.close() }
        for session in app.sessions { session.stop() }; app.sessions.removeAll()
        do { if !options.reuseFixture { try cleanupFixture(options.fixtureID) } }
        catch { code = 1; emit(["event": "error", "message": "Could not remove the disposable performance fixture."]) }
        if let report { emit(report) }
        exit(code)
    }
}
