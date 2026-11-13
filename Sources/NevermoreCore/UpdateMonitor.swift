import Foundation

/// Owns the application-wide check, schedule and persisted notice decisions.
/// All windows observe this one state; no account or chat data enters it.
@MainActor public final class UpdateMonitor {
    public enum Reason: Sendable { case automatic, manual }
    public enum Scheduling: Sendable { case automatic, manualOnly }
    public enum Result: Equatable, Sendable { case notChecked, checked, failed(String) }
    public static let automaticKey = "checksForUpdatesAutomatically"
    public static let launchDelay: Duration = .seconds(10)
    public static let interval: Duration = .seconds(24 * 60 * 60)
    private static let dismissedKey = "dismissedUpdateVersion"
    private static let announcedKey = "announcedUpdateVersion"

    public let runningVersion: ReleaseVersion
    public private(set) var offer: ReleaseOffer?
    public private(set) var isChecking = false
    public private(set) var result: Result = .notChecked
    public var onChange: (() -> Void)?
    public var onAnnouncement: ((ReleaseOffer) -> Void)?

    private let defaults: UserDefaults
    private let scheduling: Scheduling
    private let fetch: @Sendable (ReleaseVersion) async throws -> ReleaseOffer?
    private let sleep: @Sendable (Duration) async throws -> Void
    private var schedule: Task<Void, Never>?
    private var request: Task<Void, Never>?
    private var manuallyRequested = false
    private var stopped = false

    public init(runningVersion: ReleaseVersion, defaults: UserDefaults = .standard, scheduling: Scheduling = .automatic,
                fetch: @escaping @Sendable (ReleaseVersion) async throws -> ReleaseOffer? = { try await ReleaseCheck().fetch(for: $0) },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runningVersion = runningVersion
        self.defaults = defaults
        self.scheduling = scheduling
        self.fetch = fetch
        self.sleep = sleep
    }

    deinit { schedule?.cancel(); request?.cancel() }

    public var checksAutomatically: Bool { defaults.object(forKey: Self.automaticKey) as? Bool != false }
    public var visibleOffer: ReleaseOffer? {
        guard let offer else { return nil }
        if let dismissed = defaults.string(forKey: Self.dismissedKey).flatMap(ReleaseVersion.init), offer.version <= dismissed { return nil }
        return offer
    }

    public func start() {
        stopped = false
        guard scheduling == .automatic, checksAutomatically, schedule == nil else { return }
        let sleep = self.sleep
        schedule = Task { [weak self] in
            do {
                try await sleep(Self.launchDelay)
                while !Task.isCancelled {
                    await self?.check(.automatic)
                    try await sleep(Self.interval)
                }
            } catch { /* Cancellation ends the schedule; check failures do not. */ }
        }
    }

    public func stop() {
        stopped = true
        request?.cancel()
        schedule?.cancel()
        schedule = nil
    }

    public func setChecksAutomatically(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticKey)
        schedule?.cancel()
        schedule = nil
        if enabled { start() }
        onChange?()
    }

    public func dismiss() {
        guard let offer else { return }
        defaults.set(offer.version.description, forKey: Self.dismissedKey)
        onChange?()
    }

    public func check(_ reason: Reason) async {
        guard !stopped, reason == .manual || (scheduling == .automatic && checksAutomatically) else { return }
        if reason == .manual { manuallyRequested = true }
        if let request { await request.value; return }
        isChecking = true
        let fetch = self.fetch, version = runningVersion
        // The bounded request is independent of the timer: turning automatic
        // checks off must not cancel an explicit check joining the same fetch.
        // Without a manual request, opting out discards the in-flight result.
        let task = Task { [weak self] in
            do {
                let found = try await fetch(version)
                guard let self else { return }
                if canAcceptResult {
                    offer = found
                    result = .checked
                    announceIfNeeded()
                }
            } catch {
                if let self, canAcceptResult {
                    result = .failed((error as? ReleaseCheckError)?.localizedDescription ?? ReleaseCheckError.unavailable.localizedDescription)
                    // Retain a known offer on failure without claiming success.
                }
            }
            guard let self else { return }
            request = nil
            manuallyRequested = false
            isChecking = false
            onChange?()
        }
        request = task
        onChange?()
        await task.value
    }

    private var canAcceptResult: Bool { !stopped && !Task.isCancelled && (manuallyRequested || checksAutomatically) }

    private func announceIfNeeded() {
        guard let visible = visibleOffer,
              defaults.string(forKey: Self.announcedKey).flatMap(ReleaseVersion.init).map({ $0 < visible.version }) ?? true else { return }
        // Persist the attempt before handing off to the OS, so denied
        // permission or a restart cannot cause repeated prompts.
        defaults.set(visible.version.description, forKey: Self.announcedKey)
        onAnnouncement?(visible)
    }
}
