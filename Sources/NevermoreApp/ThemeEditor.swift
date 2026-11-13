import AppKit
import NevermoreCore

/// A control's action as a closure. Controls hold their target weakly, so
/// the editor keeps these alive for as long as the control exists.
@MainActor private final class ThemeEditorAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

@MainActor private final class ThemeEditorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The Customize Theme window. It edits the active theme in place: every
/// control writes one field of that preset's `ThemeCustomization`, and the
/// open windows are the preview. Presets are never modified, so Reset to
/// Preset is always available.
///
/// State ownership: `ThemeManager` owns the customization. Controls read the
/// customized theme when they act, never a copy captured when they were
/// built, so two controls editing one list (two wells of the name colors)
/// cannot overwrite each other.
@MainActor final class ThemeEditorController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppDelegate
    private(set) var themeID: ThemeID
    /// The customized theme the controls currently show.
    private var shown: Theme?
    /// Set while a control's own edit travels through the app, so the
    /// control being dragged is not rebuilt underneath the pointer.
    private var isCommitting = false
    private var actions: [ThemeEditorAction] = []
    /// Actions of the rebuilt list rows; replaced with the rows.
    private var listActions: [ThemeEditorAction] = []
    private var listWells: [NSColorWell] = []
    private var syncs: [(Theme, ThemePalette) -> Void] = []

    private let tabs = NSTabView()
    private let gradientRow = NSStackView()
    private let nameRow = NSStackView()
    private let motifRows = NSStackView()
    private let ornamentRows = NSStackView()
    private let addMotif = NSButton(title: "Add Motif", target: nil, action: nil)
    private let addOrnament = NSButton(title: "Add Ornament", target: nil, action: nil)
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let warningIcon = NSImageView()
    let resetButton = NSButton(title: "Reset to Preset…", target: nil, action: nil)

    private static let contentWidth: CGFloat = 640
    private static let tabHeight: CGFloat = 400
    private static let wellSize = NSSize(width: 38, height: 22)
    private static let sliderWidth: CGFloat = 180

    init(app: AppDelegate) {
        self.app = app
        themeID = ThemeManager.shared.current.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.tabHeight + 80), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Reading and writing the theme

    private var theme: Theme { ThemeManager.shared.customized(themeID) }

    /// Applies one change to the active theme's customization.
    /// `structural` edits add or remove list rows, which are then rebuilt.
    private func edit(structural: Bool = false, _ change: (inout ThemeCustomization) -> Void) {
        var customization = ThemeManager.shared.customization(for: themeID)
        change(&customization)
        isCommitting = true
        app.customizeTheme(themeID, customization)
        isCommitting = false
        if structural { rebuildLists() }
    }

    private func editMotifs(structural: Bool = false, _ change: (inout [MotifSpec]) -> Void) {
        var motifs = theme.wallpaper.motifs
        change(&motifs)
        edit(structural: structural) { $0.motifs = motifs }
    }

    private func editOrnaments(structural: Bool = false, _ change: (inout [OrnamentSpec]) -> Void) {
        var ornaments = theme.wallpaper.ornaments
        change(&ornaments)
        edit(structural: structural) { $0.ornaments = ornaments }
    }

    /// Follows the app: another theme was chosen, the theme was reset, or an
    /// edit of this window's own came back around.
    func reload() {
        let manager = ThemeManager.shared
        // Classic is the system look; there is nothing to edit.
        guard !manager.current.isClassic else { close(); return }
        themeID = manager.current.id
        let theme = self.theme
        let changed = theme != shown
        shown = theme
        if changed && !isCommitting {
            syncControls()
            rebuildLists()
        }
        syncStatus()
    }

    /// Removes every change to the active theme.
    func resetToPreset() {
        app.customizeTheme(themeID, ThemeCustomization())
    }

    private func syncControls() {
        guard let palette = theme.palette else { return }
        for sync in syncs { sync(theme, palette) }
    }

    private func syncStatus() {
        let manager = ThemeManager.shared
        window?.title = "Customize \(manager.current.name)"
        resetButton.isEnabled = manager.isCustomized(themeID)
        let roles = ThemeAudit.lowContrastRoles(in: manager.current).map(Self.roleName)
        warning.stringValue = roles.isEmpty ? "" : "Hard to read on this backdrop: \(roles.formatted(.list(type: .and)))."
        warning.isHidden = roles.isEmpty
        warningIcon.isHidden = roles.isEmpty
    }

    /// The low-contrast warning on screen, for the self-checks.
    var warningText: String { warning.isHidden ? "" : warning.stringValue }

    /// A control in any pane, by accessibility label or button title, for
    /// the self-checks: a tab view keeps only its selected pane in the
    /// window's view tree.
    func control(labeled label: String) -> NSControl? {
        func find(in view: NSView) -> NSControl? {
            if let control = view as? NSControl, control.accessibilityLabel() == label || (control as? NSButton)?.title == label { return control }
            for subview in view.subviews {
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        for item in tabs.tabViewItems {
            if let view = item.view, let found = find(in: view) { return found }
        }
        return nil
    }

    private static func roleName(_ role: String) -> String {
        switch role {
        case "text": "message text"
        case "code text": "code"
        case "link": "links"
        case "alert": "alerts"
        case "accent": "the accent"
        default: role.replacingOccurrences(of: "name color", with: "sender name")
        }
    }

    // MARK: Window

    private func buildContent() {
        tabs.addTabViewItem(tab("Colors", colorsPane()))
        tabs.addTabViewItem(tab("Backdrop", backdropPane()))
        tabs.addTabViewItem(tab("Wallpaper", wallpaperPane()))
        tabs.addTabViewItem(tab("Type and Effects", typePane()))
        warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        warningIcon.contentTintColor = .systemYellow
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .secondaryLabelColor
        warning.maximumNumberOfLines = 2
        warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)
        resetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        bind(resetButton, to: &actions) { [unowned self] in confirmReset() }
        let footer = NSStackView(views: [warningIcon, warning, NSView(), resetButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        let stack = NSStackView(views: [tabs, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tabs.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            tabs.heightAnchor.constraint(equalToConstant: Self.tabHeight),
            footer.widthAnchor.constraint(equalTo: tabs.widthAnchor),
        ])
        window?.contentView = content
    }

    private func confirmReset() {
        guard let window else { return }
        let name = ThemeManager.shared.current.name
        let alert = SheetPrompt.confirmationAlert("Reset \(name) to its preset?", message: "Your changes to \(name) are removed. Other themes keep theirs.", confirm: "Reset", destructive: true)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .alertSecondButtonReturn { self?.resetToPreset() }
            }
        }
    }

    /// Commits a title still being typed before the window goes away.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }

    /// The shared color panel belongs to this window's wells while it is open.
    func windowWillClose(_ notification: Notification) {
        for well in listWells { well.deactivate() }
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        app.themeEditor = nil
    }

    // MARK: Panes

    private func colorsPane() -> NSView {
        let tone = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)
        tone.setAccessibilityLabel("Appearance")
        bind(tone, to: &actions) { [unowned self] in edit { $0.tone = tone.selectedSegment == 1 ? .dark : .light } }
        syncs.append { theme, _ in tone.selectedSegment = theme.tone == .dark ? 1 : 0 }
        let glow = NSButton(checkboxWithTitle: "Glow behind sender names", target: nil, action: nil)
        bind(glow, to: &actions) { [unowned self] in edit { $0.nameGlow = glow.state == .on } }
        syncs.append { _, palette in glow.state = palette.nameGlow ? .on : .off }
        configureRow(nameRow)
        return grid([
            [label("Appearance:"), tone],
            [label("Message text:"), well("Message text", \.text, \.text)],
            [label("Secondary text:"), well("Secondary text", \.secondaryText, \.secondaryText)],
            [label("Links:"), well("Links", \.link, \.link)],
            [label("Accent:"), well("Accent", \.accent, \.accent)],
            [label("Alerts:"), well("Alerts", \.alert, \.alert)],
            [label("Composer tint:"), well("Composer tint", \.composerTint, \.composerTint)],
            [label("Sender names:"), nameRow],
            [label(""), glow],
            [label(""), note("Appearance decides the look of the system's own controls and labels. Each sender keeps one name color.")],
        ])
    }

    private func backdropPane() -> NSView {
        let angle = slider(0...359, label: "Gradient angle")
        let angleValue = valueLabel()
        bind(angle, to: &actions) { [unowned self] in
            angleValue.stringValue = Self.degrees(angle.doubleValue)
            edit { $0.gradientAngle = angle.doubleValue.rounded() }
        }
        syncs.append { _, palette in
            angle.doubleValue = palette.gradientAngle
            angleValue.stringValue = Self.degrees(palette.gradientAngle)
        }
        let tintOpacity = slider(0...1, label: "Sidebar tint opacity")
        let tintValue = valueLabel()
        bind(tintOpacity, to: &actions) { [unowned self] in
            tintValue.stringValue = Self.percent(tintOpacity.doubleValue)
            edit { $0.sidebarTintOpacity = Self.hundredths(tintOpacity.doubleValue) }
        }
        syncs.append { _, palette in
            tintOpacity.doubleValue = palette.sidebarTintOpacity
            tintValue.stringValue = Self.percent(palette.sidebarTintOpacity)
        }
        configureRow(gradientRow)
        return grid([
            [label("Gradient:"), gradientRow],
            [label("Angle:"), row([angle, angleValue])],
            [label("Sidebar tint:"), well("Sidebar tint", \.sidebarTint, \.sidebarTint)],
            [label("Tint opacity:"), row([tintOpacity, tintValue])],
            [label(""), note("The gradient runs from the first color to the last; 90° is top to bottom. Backdrop opacity for all themes is in Settings ▸ Appearance.")],
        ])
    }

    private func wallpaperPane() -> NSView {
        let density = popUp(ThemeDensity.allCases.map { Self.words($0.rawValue) }, label: "Motif density")
        bind(density, to: &actions) { [unowned self] in edit { $0.density = ThemeDensity.allCases[density.indexOfSelectedItem] } }
        syncs.append { theme, _ in density.selectItem(at: ThemeDensity.allCases.firstIndex(of: theme.wallpaper.density) ?? 0) }
        let opacity = slider(0...1, label: "Motif opacity")
        let opacityValue = valueLabel()
        bind(opacity, to: &actions) { [unowned self] in
            opacityValue.stringValue = Self.percent(opacity.doubleValue)
            edit { $0.motifOpacity = Self.hundredths(opacity.doubleValue) }
        }
        syncs.append { theme, _ in
            opacity.doubleValue = theme.wallpaper.opacity
            opacityValue.stringValue = Self.percent(theme.wallpaper.opacity)
        }
        bind(addMotif, to: &actions) { [unowned self] in appendMotif() }
        bind(addOrnament, to: &actions) { [unowned self] in appendOrnament() }
        for rows in [motifRows, ornamentRows] {
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 6
        }
        let content = grid([
            [label("Density:"), density],
            [label("Motif opacity:"), row([opacity, opacityValue])],
            [label("Motifs:"), motifRows],
            [label(""), addMotif],
            [label("Ornaments:"), ornamentRows],
            [label(""), addOrnament],
            [label(""), note("Motifs repeat across the conversation; a motif with several colors picks one per shape, and two-part motifs such as the pumpkin use them in order. Ornaments are pinned to an edge or corner.")],
        ])
        content.row(at: 2).yPlacement = .top
        content.row(at: 4).yPlacement = .top
        return content
    }

    private func typePane() -> NSView {
        let fonts = Self.displayFonts
        let display = NSPopUpButton()
        display.setAccessibilityLabel("Sender name font")
        bind(display, to: &actions) { [unowned self] in
            edit { $0.displayFont = display.selectedItem?.representedObject as? String ?? ThemeCustomization.systemDisplayFont }
        }
        syncs.append { theme, _ in
            // The chosen face joins the list even when no preset uses it
            // (a hand-edited preference, a font another Mac had).
            let current = theme.typography.displayFont
            let names = fonts + (current.map { fonts.contains($0) ? [] : [$0] } ?? [])
            display.removeAllItems()
            display.addItem(withTitle: "System")
            display.lastItem?.representedObject = ThemeCustomization.systemDisplayFont
            for name in names {
                display.addItem(withTitle: NSFont(name: name, size: 13)?.displayName ?? name)
                display.lastItem?.representedObject = name
                if let font = NSFont(name: name, size: 13) {
                    display.lastItem?.attributedTitle = NSAttributedString(string: font.displayName ?? name, attributes: [.font: font])
                }
            }
            display.selectItem(at: current.flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        let body = popUp(ThemeBodyDesign.allCases.map { Self.words($0.rawValue) }, label: "Message text design")
        bind(body, to: &actions) { [unowned self] in edit { $0.bodyDesign = ThemeBodyDesign.allCases[body.indexOfSelectedItem] } }
        syncs.append { theme, _ in body.selectItem(at: ThemeBodyDesign.allCases.firstIndex(of: theme.typography.bodyDesign) ?? 0) }
        let celebration = popUp(ThemeCelebration.allCases.map { Self.words($0.rawValue) }, label: "Celebration")
        bind(celebration, to: &actions) { [unowned self] in edit { $0.celebration = ThemeCelebration.allCases[celebration.indexOfSelectedItem] } }
        syncs.append { theme, _ in celebration.selectItem(at: ThemeCelebration.allCases.firstIndex(of: theme.celebration) ?? 0) }
        let art = motifPopUp(label: "Empty window art")
        bind(art, to: &actions) { [unowned self] in edit { $0.emptyMotif = ThemeMotif.allCases[art.indexOfSelectedItem] } }
        syncs.append { theme, _ in art.selectItem(at: theme.emptyMotif.flatMap(ThemeMotif.allCases.firstIndex(of:)) ?? 0) }
        let title = NSTextField(string: "")
        title.setAccessibilityLabel("Empty window title")
        title.widthAnchor.constraint(equalToConstant: 280).isActive = true
        // An emptied field falls back to the preset's title.
        bind(title, to: &actions) { [unowned self] in
            edit { $0.emptyTitle = title.stringValue }
            title.stringValue = theme.emptyTitle
        }
        syncs.append { theme, _ in title.stringValue = theme.emptyTitle }
        return grid([
            [label("Sender names:"), display],
            [label("Message text:"), body],
            [label("Celebration:"), celebration],
            [label("Empty window art:"), art],
            [label("Empty window title:"), title],
            [label(""), note("The composer always uses the system font. The celebration plays when you switch to this theme.")],
        ])
    }

    // MARK: List rows

    /// Rebuilds the rows whose number follows the theme: gradient stops,
    /// name colors, motifs and ornaments.
    private func rebuildLists() {
        guard let palette = theme.palette else { return }
        for well in listWells { well.deactivate() }
        listWells = []
        listActions = []
        fill(gradientRow, with: colorWells(count: palette.gradient.count, label: "Gradient color", allowed: ThemeCustomization.Limit.gradientStops,
                                           read: { $0.palette?.gradient ?? [] }, write: { $0.gradient = $1 }))
        fill(nameRow, with: colorWells(count: palette.nameColors.count, label: "Sender name color", allowed: ThemeCustomization.Limit.nameColors,
                                       read: { $0.palette?.nameColors ?? [] }, write: { $0.nameColors = $1 }))
        fill(motifRows, with: theme.wallpaper.motifs.indices.map(motifRow))
        fill(ornamentRows, with: theme.wallpaper.ornaments.indices.map(ornamentRow))
        addMotif.isEnabled = theme.wallpaper.motifs.count < ThemeCustomization.Limit.motifs
        addOrnament.isEnabled = theme.wallpaper.ornaments.count < ThemeCustomization.Limit.ornaments
    }

    private func fill(_ stack: NSStackView, with views: [NSView]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in views { stack.addArrangedSubview(view) }
        if views.isEmpty {
            let none = NSTextField(labelWithString: "None")
            none.textColor = .secondaryLabelColor
            stack.addArrangedSubview(none)
        }
    }

    /// A well per color plus − and + to shorten or extend the list within
    /// `allowed`. `read` fetches the list from the customized theme at the
    /// moment a control acts.
    private func colorWells(count: Int, label: String, allowed: ClosedRange<Int>, read: @escaping (Theme) -> [ThemeColor],
                            write: @escaping (inout ThemeCustomization, [ThemeColor]) -> Void) -> [NSView] {
        var views: [NSView] = (0..<count).map { index in
            let well = Self.makeWell("\(label) \(index + 1)")
            let colors = read(theme)
            well.color = colors.indices.contains(index) ? NSColor(theme: colors[index]) : .gray
            listWells.append(well)
            bind(well, to: &listActions) { [unowned self] in
                var colors = read(theme)
                guard colors.indices.contains(index), let color = ThemeColor(nsColor: well.color) else { return }
                colors[index] = color
                edit { write(&$0, colors) }
            }
            return well
        }
        let stepper = NSSegmentedControl(images: [NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove last color") ?? NSImage(),
                                                  NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a color") ?? NSImage()],
                                         trackingMode: .momentary, target: nil, action: nil)
        stepper.controlSize = .small
        stepper.setAccessibilityLabel("\(label) count")
        stepper.setEnabled(count > allowed.lowerBound, forSegment: 0)
        stepper.setEnabled(count < allowed.upperBound, forSegment: 1)
        bind(stepper, to: &listActions) { [unowned self] in
            var colors = read(theme)
            if stepper.selectedSegment == 0 {
                guard colors.count > allowed.lowerBound else { return }
                colors.removeLast()
            } else {
                guard colors.count < allowed.upperBound, let last = colors.last else { return }
                colors.append(last)
            }
            edit(structural: true) { write(&$0, colors) }
        }
        views.append(stepper)
        return views
    }

    private func motifRow(_ index: Int) -> NSView {
        let spec = theme.wallpaper.motifs[index]
        let motif = motifPopUp(label: "Motif \(index + 1)")
        motif.selectItem(at: ThemeMotif.allCases.firstIndex(of: spec.motif) ?? 0)
        bind(motif, to: &listActions) { [unowned self] in
            editMotifs { motifs in
                guard motifs.indices.contains(index) else { return }
                motifs[index] = MotifSpec(ThemeMotif.allCases[motif.indexOfSelectedItem], motifs[index].colors, style: motifs[index].style, weight: motifs[index].weight)
            }
        }
        let style = popUp(["Filled", "Outline", "Glow"], label: "Motif \(index + 1) style")
        style.selectItem(at: MotifStyle.allCases.firstIndex(of: spec.style) ?? 0)
        bind(style, to: &listActions) { [unowned self] in
            editMotifs { motifs in
                guard motifs.indices.contains(index) else { return }
                motifs[index] = MotifSpec(motifs[index].motif, motifs[index].colors, style: MotifStyle.allCases[style.indexOfSelectedItem], weight: motifs[index].weight)
            }
        }
        let weight = popUp((1...5).map { "\($0)×" }, label: "Motif \(index + 1) frequency")
        weight.toolTip = "How often this motif appears compared with the others."
        weight.selectItem(at: spec.weight - 1)
        bind(weight, to: &listActions) { [unowned self] in
            editMotifs { motifs in
                guard motifs.indices.contains(index) else { return }
                motifs[index] = MotifSpec(motifs[index].motif, motifs[index].colors, style: motifs[index].style, weight: weight.indexOfSelectedItem + 1)
            }
        }
        let wells = colorWells(count: spec.colors.count, label: "Motif \(index + 1) color", allowed: ThemeCustomization.Limit.colorsPerShape,
                               read: { $0.wallpaper.motifs.indices.contains(index) ? $0.wallpaper.motifs[index].colors : [] },
                               write: { [unowned self] customization, colors in
                                   var motifs = theme.wallpaper.motifs
                                   guard motifs.indices.contains(index) else { return }
                                   motifs[index] = MotifSpec(motifs[index].motif, colors, style: motifs[index].style, weight: motifs[index].weight)
                                   customization.motifs = motifs
                               })
        let remove = removeButton("Remove motif \(index + 1)") { [unowned self] in
            editMotifs(structural: true) { motifs in
                guard motifs.indices.contains(index) else { return }
                motifs.remove(at: index)
            }
        }
        return row([motif, style, weight] + wells + [remove])
    }

    private func ornamentRow(_ index: Int) -> NSView {
        let spec = theme.wallpaper.ornaments[index]
        let kind = popUp(OrnamentKind.allCases.map(Self.ornamentName), label: "Ornament \(index + 1)")
        kind.selectItem(at: OrnamentKind.allCases.firstIndex(of: spec.kind) ?? 0)
        bind(kind, to: &listActions) { [unowned self] in
            editOrnaments { ornaments in
                guard ornaments.indices.contains(index) else { return }
                ornaments[index] = OrnamentSpec(OrnamentKind.allCases[kind.indexOfSelectedItem], ornaments[index].anchor, ornaments[index].colors, opacity: ornaments[index].opacity)
            }
        }
        let anchor = popUp(OrnamentAnchor.allCases.map(Self.anchorName), label: "Ornament \(index + 1) position")
        anchor.selectItem(at: OrnamentAnchor.allCases.firstIndex(of: spec.anchor) ?? 0)
        bind(anchor, to: &listActions) { [unowned self] in
            editOrnaments { ornaments in
                guard ornaments.indices.contains(index) else { return }
                ornaments[index] = OrnamentSpec(ornaments[index].kind, OrnamentAnchor.allCases[anchor.indexOfSelectedItem], ornaments[index].colors, opacity: ornaments[index].opacity)
            }
        }
        let opacity = slider(0...1, label: "Ornament \(index + 1) opacity", width: 80)
        opacity.toolTip = "Opacity"
        opacity.doubleValue = spec.opacity
        bind(opacity, to: &listActions) { [unowned self] in
            editOrnaments { ornaments in
                guard ornaments.indices.contains(index) else { return }
                ornaments[index] = OrnamentSpec(ornaments[index].kind, ornaments[index].anchor, ornaments[index].colors, opacity: Self.hundredths(opacity.doubleValue))
            }
        }
        let wells = colorWells(count: spec.colors.count, label: "Ornament \(index + 1) color", allowed: ThemeCustomization.Limit.colorsPerShape,
                               read: { $0.wallpaper.ornaments.indices.contains(index) ? $0.wallpaper.ornaments[index].colors : [] },
                               write: { [unowned self] customization, colors in
                                   var ornaments = theme.wallpaper.ornaments
                                   guard ornaments.indices.contains(index) else { return }
                                   ornaments[index] = OrnamentSpec(ornaments[index].kind, ornaments[index].anchor, colors, opacity: ornaments[index].opacity)
                                   customization.ornaments = ornaments
                               })
        let remove = removeButton("Remove ornament \(index + 1)") { [unowned self] in
            editOrnaments(structural: true) { ornaments in
                guard ornaments.indices.contains(index) else { return }
                ornaments.remove(at: index)
            }
        }
        return row([kind, anchor, opacity] + wells + [remove])
    }

    /// A new motif starts as the first shape the wallpaper does not use yet,
    /// in the theme's accent.
    private func appendMotif() {
        guard let palette = theme.palette else { return }
        let used = Set(theme.wallpaper.motifs.map(\.motif))
        let motif = ThemeMotif.allCases.first { !used.contains($0) } ?? .dot
        editMotifs(structural: true) { $0.append(MotifSpec(motif, [palette.accent])) }
    }

    private func appendOrnament() {
        guard let palette = theme.palette else { return }
        let used = Set(theme.wallpaper.ornaments.map(\.kind))
        let kind = OrnamentKind.allCases.first { !used.contains($0) } ?? .moonLarge
        editOrnaments(structural: true) { $0.append(OrnamentSpec(kind, OrnamentArt.usualAnchor(for: kind), [palette.accent], opacity: Self.newOrnamentOpacity)) }
    }

    /// Faint enough that text stays readable over a new ornament.
    private static let newOrnamentOpacity = 0.2

    // MARK: Controls

    private func bind(_ control: NSControl, to bag: inout [ThemeEditorAction], _ run: @escaping () -> Void) {
        let action = ThemeEditorAction(run)
        bag.append(action)
        control.target = action
        control.action = #selector(ThemeEditorAction.fire(_:))
    }

    private func well(_ name: String, _ source: KeyPath<ThemePalette, ThemeColor>, _ field: WritableKeyPath<ThemeCustomization, ThemeColor?>) -> NSColorWell {
        let well = Self.makeWell(name)
        bind(well, to: &actions) { [unowned self] in
            guard let color = ThemeColor(nsColor: well.color) else { return }
            edit { $0[keyPath: field] = color }
        }
        syncs.append { _, palette in well.color = NSColor(theme: palette[keyPath: source]) }
        return well
    }

    private static func makeWell(_ name: String) -> NSColorWell {
        let well = NSColorWell(style: .default)
        well.supportsAlpha = false
        well.setAccessibilityLabel(name)
        well.toolTip = name
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: wellSize.width).isActive = true
        well.heightAnchor.constraint(equalToConstant: wellSize.height).isActive = true
        return well
    }

    private func slider(_ range: ClosedRange<Double>, label: String, width: CGFloat = sliderWidth) -> NSSlider {
        let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel(label)
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        return slider
    }

    private func popUp(_ titles: [String], label: String) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.addItems(withTitles: titles)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.setAccessibilityLabel(label)
        return button
    }

    private func motifPopUp(label: String) -> NSPopUpButton {
        let button = popUp(ThemeMotif.allCases.map { Self.words($0.rawValue) }, label: label)
        for (item, motif) in zip(button.itemArray, ThemeMotif.allCases) { item.image = Self.motifIcon(motif) }
        return button
    }

    private func removeButton(_ label: String, _ run: @escaping () -> Void) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        bind(button, to: &listActions, run)
        return button
    }

    private func tab(_ title: String, _ content: NSView) -> NSTabViewItem {
        let document = ThemeEditorDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -14),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let item = NSTabViewItem()
        item.label = title
        item.view = scroll
        return item
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        // Color wells and sliders have no baseline to share with a label.
        grid.rowAlignment = .none
        grid.yPlacement = .center
        return grid
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        configureRow(stack)
        return stack
    }

    private func configureRow(_ stack: NSStackView) {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func valueLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        field.preferredMaxLayoutWidth = 400
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        return field
    }

    // MARK: Names and formats

    /// The display faces the presets use that this Mac has, by PostScript name.
    private static let displayFonts: [String] = {
        var seen = Set<String>()
        return ThemeCatalog.all.compactMap(\.typography.displayFont).filter { seen.insert($0).inserted && NSFont(name: $0, size: 13) != nil }
    }()

    private static var motifIcons: [ThemeMotif: NSImage] = [:]

    /// A motif's silhouette as a menu icon in the menu's own text color.
    private static func motifIcon(_ motif: ThemeMotif) -> NSImage {
        if let icon = motifIcons[motif] { return icon }
        let black = ThemeColor(0x000000)
        let icon = MotifArt.image(motif, colors: [black, black, black], style: .fill, size: 16)
        icon.isTemplate = true
        motifIcons[motif] = icon
        return icon
    }

    /// "candyCorn" as "Candy Corn".
    static func words(_ camelCase: String) -> String {
        var result = ""
        for character in camelCase {
            if character.isUppercase && !result.isEmpty { result.append(" ") }
            // Uppercasing can yield several characters ("ß" becomes "SS").
            if result.isEmpty { result.append(contentsOf: character.uppercased()) } else { result.append(character) }
        }
        return result
    }

    private static func ornamentName(_ kind: OrnamentKind) -> String {
        kind == .moonLarge ? "Large Moon" : words(kind.rawValue)
    }

    /// Ornaments are pinned to the pane's physical edges, so the positions
    /// say left and right rather than leading and trailing.
    private static func anchorName(_ anchor: OrnamentAnchor) -> String {
        switch anchor {
        case .topLeading: "Top Left"
        case .topTrailing: "Top Right"
        case .bottomLeading: "Bottom Left"
        case .bottomTrailing: "Bottom Right"
        case .top: "Top"
        case .bottom: "Bottom"
        case .fill: "Whole Pane"
        }
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private static func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
    /// Sliders report long fractions; opacities are stored to two places.
    static func hundredths(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
