import AppKit
import ServiceManagement

@MainActor
final class LoginItemPreferences: NSStackView {
    private let checkbox = NSButton(checkboxWithTitle: "Open Nevermore at login", target: nil, action: nil)
    private let openSettingsButton = NSButton(title: "Open Login Items Settings…", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
        refreshStatus()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
        refreshStatus()
    }

    private func configure() {
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false

        checkbox.target = self
        checkbox.action = #selector(toggleLoginItem)
        checkbox.setContentHuggingPriority(.required, for: .vertical)

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openLoginItemsSettings)
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.setContentHuggingPriority(.required, for: .vertical)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = false
        statusLabel.usesSingleLineMode = false
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityElement(true)
        statusLabel.setAccessibilityRole(.staticText)

        addArrangedSubview(checkbox)
        addArrangedSubview(openSettingsButton)
        addArrangedSubview(statusLabel)
    }

    func refreshStatus(errorMessage: String? = nil) {
        let status = SMAppService.mainApp.status
        checkbox.state = status == .enabled || status == .requiresApproval ? .on : .off
        openSettingsButton.isHidden = status != .requiresApproval

        if let errorMessage {
            statusLabel.stringValue = errorMessage
            statusLabel.textColor = .systemRed
            statusLabel.setAccessibilityLabel("Login item status")
            statusLabel.setAccessibilityValue(errorMessage)
            return
        }

        statusLabel.textColor = .secondaryLabelColor
        let message = statusMessage(for: status)
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel("Login item status")
        statusLabel.setAccessibilityValue(message)
    }

    private func statusMessage(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "Nevermore will open when you log in."
        case .requiresApproval:
            return "Login item registration needs approval in System Settings."
        case .notRegistered:
            return "Nevermore will not open when you log in."
        case .notFound:
            return "Login item status is unavailable because the app service was not found."
        @unknown default:
            return "Login item status is unavailable."
        }
    }

    @objc private func toggleLoginItem() {
        let shouldEnable = checkbox.state == .on
        do {
            if shouldEnable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
        } catch {
            refreshStatus(errorMessage: "Could not update login item: \(error.localizedDescription)")
        }
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
        refreshStatus()
    }
}
