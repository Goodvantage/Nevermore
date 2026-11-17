import AppKit

/// A toolbar search field in a glass capsule of its own.
///
/// On macOS 26 `NSSearchToolbarItem` sits in the toolbar's interactive
/// glass, which scales the capsule's contents by about 0.7 % while the
/// mouse button is down but leaves the focus ring where it is. Every click
/// in the field then nudges the magnifier and text left and the clear
/// button right, about a point each, inside a ring that stays still. An
/// unbordered item that brings its own glass keeps the capsule without
/// the press effect.
///
/// The stock item also collapses to a magnifier button when the toolbar
/// runs short of room. This one only shrinks to `minimumWidth`.
@MainActor final class GlassSearchToolbarItem: NSToolbarItem {
    /// The width macOS 26 gives `NSSearchToolbarItem` when the toolbar has
    /// room; matching it keeps the toolbar's layout as it was.
    private static let idealWidth: CGFloat = 325
    /// The toolbar's search field metrics on macOS 26: AppKit sets this
    /// size on the stock item's field, which makes it 36 pt tall.
    private static let controlSize: NSControl.ControlSize = .extraLarge

    init(itemIdentifier: NSToolbarItem.Identifier, searchField: NSSearchField, minimumWidth: CGFloat) {
        super.init(itemIdentifier: itemIdentifier)
        searchField.controlSize = Self.controlSize
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.contentView = searchField
        glass.translatesAutoresizingMaskIntoConstraints = false
        let height = searchField.intrinsicContentSize.height
        glass.cornerRadius = height / 2
        let ideal = glass.widthAnchor.constraint(equalToConstant: max(minimumWidth, Self.idealWidth))
        ideal.priority = .defaultLow
        NSLayoutConstraint.activate([
            glass.heightAnchor.constraint(equalToConstant: height),
            glass.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
            ideal,
        ])

        view = glass
        // Bordered items get the toolbar's interactive glass around the
        // view, which brings the press effect back.
        isBordered = false
    }
}
