import AppKit
import NevermoreCore

/// Settings ▸ GIFs: whether GIFs in messages load, which service the
/// picker searches, its key and how strictly it filters.
@MainActor final class GIFSettings: NSObject, NSTextFieldDelegate {
    let showsInMessages = NSButton(checkboxWithTitle: "Show GIFs from GIF services in messages", target: nil, action: nil)
    let provider = NSPopUpButton()
    let key = NSSecureTextField()
    let getKey = NSButton(title: "Get a Key…", target: nil, action: nil)
    let rating = NSPopUpButton()
    let keyStatus = NSTextField(labelWithString: "")
    private let keys: any GIFServiceKeyStoring
    /// Called after a change that alters how transcripts look.
    var onChange: () -> Void = {}

    init(keys: any GIFServiceKeyStoring = KeychainGIFServiceKeyStore()) {
        self.keys = keys
        super.init()
        provider.addItems(withTitles: GIFProvider.allCases.map(\.name))
        provider.setAccessibilityLabel("GIF service")
        rating.addItems(withTitles: GIFRating.allCases.map(\.title))
        rating.setAccessibilityLabel("GIF content rating")
        key.setAccessibilityLabel("GIF service key")
        key.widthAnchor.constraint(equalToConstant: 260).isActive = true
        key.delegate = self
        keyStatus.font = .systemFont(ofSize: 11); keyStatus.textColor = .secondaryLabelColor
        for (control, action) in [(showsInMessages, #selector(changeShowsInMessages)), (provider, #selector(changeProvider)), (rating, #selector(changeRating)), (key, #selector(saveKey)), (getKey, #selector(openKeyPage))] as [(NSControl, Selector)] {
            control.target = self; control.action = action
        }
        reload()
    }

    func rows(label: (String) -> NSTextField, note: (String) -> NSTextField) -> [[NSView]] {
        let keyRow = NSStackView(views: [key, getKey]); keyRow.spacing = 8
        return [
            [label("In messages:"), showsInMessages],
            [label(""), note("A GIF in a message is loaded from the GIF service that hosts it (KLIPY, GIPHY or Tenor), over HTTPS, without cookies and without your Raven account. That service sees your network address. Other images in messages are never loaded.")],
            [label("Search with:"), provider],
            [label("Key:"), keyRow],
            [label(""), keyStatus],
            [label(""), note("Searching needs a developer key from the service; its free key allows about 100 searches an hour. The key stays in your Keychain. Searches go from this Mac to the service with the key and a random identifier, never with your Raven account. A GIF you send is linked from the service, so everyone who reads it loads it from there.")],
            [label("Content:"), rating],
        ]
    }

    var selectedProvider: GIFProvider { GIFProvider.allCases.indices.contains(provider.indexOfSelectedItem) ? GIFProvider.allCases[provider.indexOfSelectedItem] : .standard }

    func reload() {
        let defaults = UserDefaults.standard
        showsInMessages.state = GIFPreferences.showsInMessages(storedValue: defaults.object(forKey: GIFPreferences.showsInMessagesKey)) ? .on : .off
        let chosen = GIFProvider(storedValue: defaults.string(forKey: GIFProvider.defaultsKey))
        provider.selectItem(at: GIFProvider.allCases.firstIndex(of: chosen) ?? 0)
        rating.selectItem(at: GIFRating.allCases.firstIndex(of: GIFRating(storedValue: defaults.string(forKey: GIFRating.defaultsKey))) ?? 0)
        reloadKey()
    }

    private func reloadKey() {
        let service = selectedProvider
        key.placeholderString = "Paste your \(service.name) key"
        let stored = keys.key(for: service)
        key.stringValue = stored ?? ""
        keyStatus.stringValue = stored == nil ? "No \(service.name) key yet. GIF search stays off until you add one." : "The \(service.name) key is saved in your Keychain."
    }

    @objc func changeShowsInMessages() {
        UserDefaults.standard.set(showsInMessages.state == .on, forKey: GIFPreferences.showsInMessagesKey)
        onChange()
    }

    @objc func changeProvider() {
        UserDefaults.standard.set(selectedProvider.rawValue, forKey: GIFProvider.defaultsKey)
        reloadKey()
    }

    @objc func changeRating() {
        guard GIFRating.allCases.indices.contains(rating.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(GIFRating.allCases[rating.indexOfSelectedItem].rawValue, forKey: GIFRating.defaultsKey)
    }

    func controlTextDidEndEditing(_ notification: Notification) { saveKey() }

    @objc func saveKey() {
        let service = selectedProvider
        let entered = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entered != (keys.key(for: service) ?? "") else { return }
        do {
            try keys.setKey(entered, for: service)
            reloadKey()
        } catch {
            keyStatus.stringValue = error.localizedDescription
        }
    }

    @objc func openKeyPage() { NSWorkspace.shared.open(selectedProvider.keyPage) }
}

/// Settings panes that other parts of the app open directly.
enum SettingsPane { case gifs }
