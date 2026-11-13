import AppKit
import RavenProtocol
import NevermoreCore

/// Local, account-scoped quiet-hours storage.
///
/// Raven has no per-user quiet-hours window on the server (verified at the
/// pinned Raven revision: Raven User stores only `quiet_hours_nudge`; the
/// organization working-hours window is a Raven Settings singleton). This
/// store is therefore an explicitly local fallback. An account-specific preference key scopes the
/// value to one account UUID so removing or re-adding an account does not mix
/// windows between accounts.
@MainActor
public enum NotificationPreferenceStore {
    private static func defaults(accountID: UUID) -> UserDefaults {
        .standard
    }

    private static func key(accountID: UUID) -> String { "quietHours.\(accountID.uuidString)" }

    /// The account's locally stored quiet-hours window, or nil when unset.
    public static func quietHours(accountID: UUID) -> QuietHours? {
        guard let data = defaults(accountID: accountID).data(forKey: key(accountID: accountID)) else { return nil }
        return try? JSONDecoder().decode(QuietHours.self, from: data)
    }

    /// Stores the account's local quiet-hours window. Passing nil clears it.
    public static func setQuietHours(_ quietHours: QuietHours?, accountID: UUID) {
        let defaults = defaults(accountID: accountID)
        let storageKey = key(accountID: accountID)
        if let quietHours, let data = try? JSONEncoder().encode(quietHours) {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}

/// Native account preferences window: server-backed availability, custom
/// status, read receipts, and after-hours nudge, plus an explicitly local
/// quiet-hours window.
@MainActor
private final class PreferencesDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor final class AccountPreferencesController: NSWindowController, NSWindowDelegate {
    private let session: AccountSession
    private let siteTimeZone: TimeZone
    private let siteTimeZoneName: String

    private let accountLabel = NSTextField(labelWithString: "")
    private let availabilityLabel = NSTextField(labelWithString: "Availability (server)")
    private let availability = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "Custom status (server)")
    private let statusField = NSTextField(string: "")
    private let hideReceipts = NSButton(checkboxWithTitle: "Hide read receipts (server)", target: nil, action: nil)
    private let nudgeLabel = NSTextField(labelWithString: "After-hours messaging (server)")
    private let nudge = NSPopUpButton()
    private let serverNote = NSTextField(wrappingLabelWithString: "")
    private let localTitle = NSTextField(labelWithString: "Local quiet hours (this Mac only)")
    private let localEnabled = NSButton(checkboxWithTitle: "Suppress notifications during these hours", target: nil, action: nil)
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let timeZoneNote = NSTextField(wrappingLabelWithString: "")
    private let orgHoursNote = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")

    private var preferences: RavenUserPreferences?
    private var ravenUserName = ""
    private var serverAvailable = false
    private var serverWritable = false
    private var saving = false
    private var closed = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var active: Bool { !closed && !session.stopped && !Task.isCancelled }

    init(session: AccountSession) {
        self.session = session
        let resolved = TimeZone(identifier: session.account.timezone) ?? TimeZone(secondsFromGMT: 0)!
        self.siteTimeZone = resolved
        if TimeZone(identifier: session.account.timezone) != nil {
            self.siteTimeZoneName = session.account.timezone
        } else if session.account.timezone.isEmpty {
            self.siteTimeZoneName = "UTC (site timezone missing)"
        } else {
            self.siteTimeZoneName = "\(session.account.timezone) (unrecognized; UTC used)"
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Account Preferences"; window.delegate = self
        window.minSize = NSSize(width: 560, height: 640)
        window.center()
        configure()
        loadInitialValues()

    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        guard !session.stopped else { return }
        let reload = closed || window?.isVisible != true
        closed = false; super.showWindow(sender)
        if reload { saveButton.isEnabled = !saving; loadInitialValues(); loadTask?.cancel(); loadTask = Task { await loadServerPreferences() } }
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; loadTask?.cancel(); saveTask?.cancel()
        preferences = nil; ravenUserName = ""; serverAvailable = false; serverWritable = false
        accountLabel.stringValue = ""; statusField.stringValue = ""; status.stringValue = ""
        availability.removeAllItems(); nudge.removeAllItems(); setServerControlsEnabled(false)
    }

    // MARK: - Construction

    private func configure() {
        accountLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        accountLabel.lineBreakMode = .byTruncatingMiddle

        for option in RavenUserPreferences.availabilityOptions {
            availability.addItem(withTitle: option.isEmpty ? "Not set" : option)
            availability.lastItem?.representedObject = option
        }
        statusField.placeholderString = "What's your status?"

        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinute]
            picker.timeZone = siteTimeZone

        }
        localEnabled.target = self
        localEnabled.action = #selector(localEnabledChanged)

        serverNote.textColor = .secondaryLabelColor
        timeZoneNote.textColor = .secondaryLabelColor
        orgHoursNote.textColor = .secondaryLabelColor
        status.textColor = .secondaryLabelColor

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        setServerControlsEnabled(false)
        localEnabledChanged()

        let fromLabel = NSTextField(labelWithString: "From")
        let toLabel = NSTextField(labelWithString: "To")
        let times = NSStackView(views: [fromLabel, startPicker, toLabel, endPicker])
        times.orientation = .horizontal
        times.spacing = 10

        let stack = NSStackView(views: [
            accountLabel,
            availabilityLabel, availability,
            statusLabel, statusField,
            hideReceipts,
            nudgeLabel, nudge,
            serverNote,
            localTitle, localEnabled, times,
            timeZoneNote,
            orgHoursNote,
            saveButton, status,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = PreferencesDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; document.addSubview(stack); content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            accountLabel.widthAnchor.constraint(equalTo: stack.widthAnchor), statusField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            serverNote.widthAnchor.constraint(equalTo: stack.widthAnchor), timeZoneNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            orgHoursNote.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func loadInitialValues() {
        let displayName = session.account.displayName.isEmpty ? session.account.user : session.account.displayName
        let host = session.account.origin.host ?? session.account.origin.absoluteString
        accountLabel.stringValue = "\(displayName) · \(session.account.user) · \(host)"

        let stored = NotificationPreferenceStore.quietHours(accountID: session.account.id)
        let quiet = stored ?? QuietHours(startMinute: 22 * 60, endMinute: 6 * 60, timezone: siteTimeZone.identifier, enabled: false)
        localEnabled.state = quiet.enabled ? .on : .off
        startPicker.dateValue = date(minuteOfDay: quiet.startMinute)
        endPicker.dateValue = date(minuteOfDay: quiet.endMinute)
        localEnabledChanged()

        timeZoneNote.stringValue = "Times use the site timezone: \(siteTimeZoneName). Quiet hours above apply only on this Mac. Raven’s working hours are set by your administrator."
        serverNote.stringValue = "Loading server preferences…"
        orgHoursNote.stringValue = "Loading site working hours…"
    }

    // MARK: - Server preferences

    private func loadServerPreferences() async {
        guard active else { return }
        guard !session.demo else {
            serverNote.stringValue = "Demo mode: Raven preferences are unavailable. Local quiet hours still save."
            orgHoursNote.stringValue = "Site working hours: not configured in this demo."; return
        }
        let client = session.client
        do {
            let raw = try await client.rpc("raven.api.raven_users.get_current_raven_user")
            guard active else { return }
            let prefs = try validatedPreferences(raw)
            session.userPreferences = prefs
            self.preferences = prefs
            self.ravenUserName = prefs.name.isEmpty ? session.account.user : prefs.name
            self.serverAvailable = true
            self.serverWritable = !session.readOnly && !session.demo
            updateServerControls(prefs)
            setServerControlsEnabled(serverWritable)
            serverNote.stringValue = serverWritable
                ? "Availability, status, read receipts, and after-hours messaging sync with Raven."
                : "This account is read-only; server preferences cannot be changed. Local quiet hours still save."
        } catch {
            guard active else { return }
            serverAvailable = false
            serverWritable = false
            setServerControlsEnabled(false)
            serverNote.stringValue = "Server preferences are unavailable: \(error.localizedDescription) Local quiet hours still save."
        }

        // The org working-hours window is read-only and lives on Raven Settings;
        // boot exposes it only when an admin configured it.
        do {
            let boot = try await client.rpc("raven.api.native.boot")
            guard active else { return }
            if case .object = boot["quiet_hours"] {
                let config = RavenQuietHoursConfig(raw: boot["quiet_hours"])
                if let start = config.startMinute, let end = config.endMinute {
                    orgHoursNote.stringValue = String(format: "Site working hours (server, read-only, site timezone): %02d:%02d–%02d:%02d. Admins configure these; the after-hours nudge uses them.", start / 60, start % 60, end / 60, end % 60)
                } else {
                    orgHoursNote.stringValue = "Site working hours: configured with unreadable times. The after-hours nudge has no effect."
                }
            } else {
                orgHoursNote.stringValue = "Site working hours: not configured. The after-hours nudge has no effect until an admin configures them."
            }
        } catch {
            guard active else { return }
            orgHoursNote.stringValue = "Site working hours could not be loaded. The after-hours nudge may still be stored on the server."
        }
    }

    private func updateServerControls(_ prefs: RavenUserPreferences) {
        availability.removeAllItems()
        for option in RavenUserPreferences.availabilityOptions {
            availability.addItem(withTitle: option.isEmpty ? "Not set" : option)
            availability.lastItem?.representedObject = option
        }
        if let index = RavenUserPreferences.availabilityOptions.firstIndex(of: prefs.availabilityStatus) {
            availability.selectItem(at: index)
        } else if prefs.availabilityStatus.isEmpty {
            availability.selectItem(at: 0)
        } else {
            // Preserve an unknown server value without making it silently writable.
            availability.addItem(withTitle: "Unsupported: \(prefs.availabilityStatus)")
            availability.lastItem?.representedObject = prefs.availabilityStatus
            availability.selectItem(at: availability.numberOfItems - 1)
            availability.isEnabled = false
        }
        statusField.stringValue = prefs.customStatus
        hideReceipts.state = prefs.hideReadReceipts ? .on : .off

        nudge.removeAllItems()
        if prefs.quietHoursNudgeRaw.isEmpty || prefs.quietHoursNudgeRaw == prefs.quietHoursNudge.rawValue {
            for value in RavenQuietHoursNudge.allCases {
                nudge.addItem(withTitle: value.rawValue)
                nudge.lastItem?.representedObject = value
            }
            if let index = RavenQuietHoursNudge.allCases.firstIndex(of: prefs.quietHoursNudge) {
                nudge.selectItem(at: index)
            }
        } else {
            // Preserve an unknown server value without making it silently writable.
            nudge.addItem(withTitle: "Unsupported: \(prefs.quietHoursNudgeRaw)")
            nudge.lastItem?.representedObject = prefs.quietHoursNudgeRaw
            nudge.selectItem(at: 0)
            nudge.isEnabled = false
        }
    }

    private func setServerControlsEnabled(_ enabled: Bool) {
        let fields = preferences?.raw.object ?? [:]
        availability.isEnabled = enabled && fields.keys.contains("availability_status") && RavenUserPreferences.availabilityOptions.contains(preferences?.availabilityStatus ?? "")
        statusField.isEnabled = enabled && fields.keys.contains("custom_status")
        hideReceipts.isEnabled = enabled && fields.keys.contains("hide_read_receipts")
        nudge.isEnabled = enabled && fields.keys.contains("quiet_hours_nudge") && (preferences?.quietHoursNudgeRaw.isEmpty == true || RavenQuietHoursNudge(rawValue: preferences?.quietHoursNudgeRaw ?? "") != nil)
    }

    private var availabilityValue: String { (availability.selectedItem?.representedObject as? String) ?? "" }
    private var nudgeValue: RavenQuietHoursNudge { (nudge.selectedItem?.representedObject as? RavenQuietHoursNudge) ?? .nudge }

    @objc private func localEnabledChanged() {
        let enabled = localEnabled.state == .on
        startPicker.isEnabled = enabled
        endPicker.isEnabled = enabled
    }

    // MARK: - Save

    @objc func save() {
        guard active, !saving else { return }
        let localQuiet = QuietHours(startMinute: minute(of: startPicker.dateValue), endMinute: minute(of: endPicker.dateValue), timezone: siteTimeZone.identifier, enabled: localEnabled.state == .on)
        // Save synchronously: account removal cannot race a later task into restoring this key.
        NotificationPreferenceStore.setQuietHours(localQuiet, accountID: session.account.id)
        guard serverWritable, !session.readOnly, !session.demo, let prefs = preferences, !ravenUserName.isEmpty else {
            status.stringValue = "Saved local quiet hours. Raven preferences were unchanged."; return
        }
        let values = prefs.mutation(
            availabilityStatus: availability.isEnabled ? availabilityValue : nil,
            customStatus: statusField.isEnabled ? statusField.stringValue : nil,
            hideReadReceipts: hideReceipts.isEnabled ? hideReceipts.state == .on : nil,
            quietHoursNudge: nudge.isEnabled ? nudgeValue : nil)
        guard !values.isEmpty else { status.stringValue = "Saved local quiet hours. Raven preferences were unchanged."; return }
        saving = true; saveButton.isEnabled = false; status.stringValue = "Saving…"
        let serverName = ravenUserName
        session.userPreferences = nil
        saveTask = Task {
            defer { saving = false; if active { saveButton.isEnabled = true } }
            do {
                guard active else { return }
                let raw = try await session.mutateResource("Raven User", name: serverName, values: values)
                guard active else { return }
                let refreshed = try validatedPreferences(raw)
                preferences = refreshed; session.userPreferences = refreshed
                updateServerControls(refreshed); setServerControlsEnabled(serverWritable); session.notify()
                status.stringValue = "Saved local quiet hours and Raven preferences."
            } catch {
                guard active else { return }
                // A response can be lost after the update committed. Read once, never repeat the mutation.
                if let raw = try? await session.client.rpc("raven.api.raven_users.get_current_raven_user"), active,
                   let current = try? validatedPreferences(raw) {
                    preferences = current; session.userPreferences = current
                    updateServerControls(current); setServerControlsEnabled(serverWritable); session.notify()
                }
                guard active else { return }
                status.stringValue = "Local quiet hours saved. Raven could not confirm the update: \(error.localizedDescription)"
            }
        }
    }

    private func validatedPreferences(_ raw: JSONValue) throws -> RavenUserPreferences {
        guard case .object = raw, raw["name"].string == session.account.user,
              raw["user"] == .null || raw["user"].string == session.account.user else { throw RavenError.invalidResponse }
        return RavenUserPreferences(raw: raw)
    }

    // MARK: - Time helpers

    private func date(minuteOfDay: Int) -> Date {
        let clamped = max(0, min(1439, minuteOfDay))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = siteTimeZone
        // Use a stable calendar date, rather than elapsed minutes since today's
        // midnight (which shifts the picker by an hour on a DST transition day).
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: clamped / 60, minute: clamped % 60)) ?? Date(timeIntervalSince1970: 0)
    }

    private func minute(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = siteTimeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
