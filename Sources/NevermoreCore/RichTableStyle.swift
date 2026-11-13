import Foundation

public enum RichTableAlignment: String, Sendable { case left, center, right }

/// Only the sizing/alignment metadata Raven's table editor emits, not arbitrary
/// CSS. These values are preserved on the wire; native tables still fit the pane.
enum RichTableStyle {
    static func declaration(_ style: String, tag: String) -> (property: String, value: String)? {
        let pieces = style.split(separator: ";", omittingEmptySubsequences: true)
        guard pieces.count == 1 else { return nil }
        let pair = pieces[0].split(separator: ":", omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let property = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["table", "col"].contains(tag), ["width", "min-width"].contains(property), pixels(value, maximum: tag == "table" ? 400_000 : 20_000) != nil { return (property, value) }
        if ["td", "th"].contains(tag), property == "text-align", RichTableAlignment(rawValue: value) != nil { return (property, value) }
        return nil
    }

    static func pixels(_ value: String, maximum: Double = 20_000) -> Double? {
        guard value.hasSuffix("px") else { return nil }
        let number = value.dropLast(2)
        guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              let amount = Double(number), amount.isFinite, amount > 0, amount <= maximum else { return nil }
        return amount
    }

    static func validCellWidths(_ value: String, span: Int) -> Bool {
        let widths = value.split(separator: ",", omittingEmptySubsequences: false)
        return span > 0 && span <= 20 && widths.count == span && widths.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) && Int($0).map { (0...20_000).contains($0) } == true
        }
    }

    static func alignment(_ node: RichNode) -> RichTableAlignment? {
        guard case .element(let tag, let attrs, _) = node else { return nil }
        if let style = attrs["style"], let declaration = declaration(style, tag: tag), declaration.property == "text-align" { return RichTableAlignment(rawValue: declaration.value) }
        return attrs["align"].flatMap(RichTableAlignment.init(rawValue:))
    }

    static func totalWidth(of columns: [RichNode]) -> String? {
        var total = 0.0, fixed = true
        for column in columns {
            guard case .element("col", let attrs, _) = column,
                  let style = attrs["style"], let declaration = declaration(style, tag: "col"), let value = pixels(declaration.value) else { return nil }
            total += value
            fixed = fixed && declaration.property == "width"
        }
        let value = total.rounded() == total ? String(Int(total)) : String(total)
        return "\(fixed ? "width" : "min-width"): \(value)px"
    }
}
