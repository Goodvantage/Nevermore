import AppKit
import NevermoreCore
import OSLog
// Xcode 26's UNNotification* SDK types are non-Sendable. All notification
// objects here stay on the main actor, including across the OS calls.
@preconcurrency import UserNotifications

extension Notification.Name {
    static let appUpdateChanged = Notification.Name("appUpdateChanged")
}

/// Native presentation for the advisory apps-site checker. Download always
/// goes through the user's browser; no installer or app replacement runs here.
@MainActor final class AppUpdateController: NSObject {
    private let monitor: UpdateMonitor?
    private let openURL: (URL) -> Bool
    private var panel: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let download = NSButton(title: "Download", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss This Version", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check for Updates Now", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private static let logger = Logger(subsystem: "ch.goodvantage.Nevermore", category: "updates")
    nonisolated static let notificationID = "nevermore-software-update"

    init(monitor: UpdateMonitor? = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap(ReleaseVersion.init).map {
            UpdateMonitor(runningVersion: $0, scheduling: CommandLine.arguments.contains(where: { ["--demo", "--self-check", "--performance-check"].contains($0) }) ? .manualOnly : .automatic)
        }, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.monitor = monitor
        self.openURL = openURL
        super.init()
        monitor?.onChange = { [weak self] in self?.refresh() }
        monitor?.onAnnouncement = { [weak self] offer in self?.announce(offer) }
    }

    var checksAutomatically: Bool { monitor?.checksAutomatically ?? false }
    var visibleVersion: String? { monitor?.visibleOffer?.version.description }
    var menuTitle: String { visibleVersion == nil ? "Check for Updates…" : "Update Available…" }
    var statusText: String {
        guard let monitor else { return "This build has no valid release version. Download a packaged release from the website." }
        if monitor.isChecking { return "Checking for updates…" }
        if case .failed(let message) = monitor.result { return message }
        if let offer = monitor.offer { return "Nevermore \(offer.version) is available. You are running \(monitor.runningVersion). Download the DMG and install it yourself; Nevermore will not replace itself." }
        if monitor.result == .checked { return "No newer macOS release is available. You are running Nevermore \(monitor.runningVersion)." }
        return "Nevermore \(monitor.runningVersion). Check the \(monitor.runningVersion.isPrerelease ? "beta" : "stable") channel for a newer release."
    }

    func start() { monitor?.start() }
    func stop() { monitor?.stop() }
    func setChecksAutomatically(_ enabled: Bool) { monitor?.setChecksAutomatically(enabled) }

    func checkNow() {
        show()
        guard let monitor else { return }
        Task { await monitor.check(.manual) }
    }

    func show() {
        if panel == nil { makePanel() }
        refresh()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() {
        let website = NSButton(title: "Open Website", target: self, action: #selector(openWebsite))
        download.target = self; download.action = #selector(downloadUpdate)
        dismissButton.target = self; dismissButton.action = #selector(dismissUpdate)
        checkButton.target = self; checkButton.action = #selector(checkFromButton)
        automatic.target = self; automatic.action = #selector(toggleAutomatic)
        let actions = NSStackView(views: [download, website, dismissButton])
        let privacy = NSTextField(wrappingLabelWithString: "Checks contact apps.goodvantage.cloud after launch and daily. No Raven account data or credentials are sent.")
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [status, actions, automatic, checkButton, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        status.widthAnchor.constraint(equalToConstant: 440).isActive = true
        privacy.widthAnchor.constraint(equalToConstant: 440).isActive = true
        status.stringValue = statusText
        let controller = NSViewController()
        controller.view = stack
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.setContentSize(stack.fittingSize)
        window.title = "Nevermore Updates"
        window.isReleasedWhenClosed = false
        window.center()
        panel = window
    }

    private func refresh() {
        status.stringValue = statusText
        download.isHidden = monitor?.offer == nil
        dismissButton.isHidden = monitor?.visibleOffer == nil
        checkButton.isEnabled = monitor != nil && monitor?.isChecking == false
        automatic.isEnabled = monitor != nil
        automatic.state = checksAutomatically ? .on : .off
        (NSApp.delegate as? AppDelegate)?.refreshUpdateMenuTitles()
        NotificationCenter.default.post(name: .appUpdateChanged, object: self)
        if case .failed = monitor?.result { Self.logger.notice("An update check failed; no account data was involved.") }
    }

    private func announce(_ offer: ReleaseOffer) {
        // A manual check already presents the offer. Background checks never
        // steal focus, and denied notification permission leaves the banner.
        guard panel?.isVisible != true, Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true,
                  monitor?.visibleOffer?.version == offer.version else { return }
            let content = UNMutableNotificationContent()
            content.title = "Nevermore update available"
            content.body = "Version \(offer.version) is ready to download. Open Nevermore to review it."
            do { try await center.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)) }
            catch { Self.logger.notice("The update notification could not be delivered.") }
        }
    }

    @objc private func checkFromButton() { checkNow() }
    @objc private func toggleAutomatic() { setChecksAutomatically(automatic.state == .on) }
    @objc private func downloadUpdate() {
        guard let url = monitor?.offer?.downloadURL else { return }
        if !openURL(url) { status.stringValue = "Could not open your browser. Try Open Website instead." }
    }
    @objc private func openWebsite() {
        if !openURL(ReleaseOffer.websiteURL) { status.stringValue = "Could not open your browser. Visit apps.goodvantage.cloud to download Nevermore." }
    }
    @objc func dismissUpdate() {
        monitor?.dismiss()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }
}

/// A compact, persistent notice shared by every conversation sidebar.
@MainActor final class UpdateNoticeView: NSStackView {
    private let updates: AppUpdateController
    private let notice = NSButton(title: "Update Available…", target: nil, action: nil)

    init(updates: AppUpdateController) {
        self.updates = updates
        super.init(frame: .zero)
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss this update")!, target: updates, action: #selector(AppUpdateController.dismissUpdate))
        dismiss.isBordered = false
        notice.isBordered = false; notice.contentTintColor = .themeAccent
        notice.target = self; notice.action = #selector(showUpdate)
        orientation = .horizontal; spacing = 6
        edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 10)
        addArrangedSubview(notice); addArrangedSubview(dismiss)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .appUpdateChanged, object: updates)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showUpdate() { updates.show() }
    @objc private func refresh() {
        isHidden = updates.visibleVersion == nil
        notice.setAccessibilityLabel(updates.visibleVersion.map { "Nevermore \($0) is available" } ?? "No update available")
    }
}

@MainActor extension AppDelegate {
    func refreshUpdateMenuTitles() {
        for menu in [NSApp.mainMenu?.items.first?.submenu, menuBarItem?.menu] {
            menu?.items.first(where: { $0.action == #selector(checkForUpdates) })?.title = updates.menuTitle
        }
    }
}
