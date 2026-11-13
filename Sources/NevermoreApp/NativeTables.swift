import AppKit
import NevermoreCore

@MainActor enum NativeTables {
    static func table(columns: Int) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        return table
    }
    static func block(for cell: RichTableLayout.Cell, in table: NSTextTable, fontSize: CGFloat) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: table, startingRow: cell.row, rowSpan: cell.rowSpan, startingColumn: cell.column, columnSpan: cell.columnSpan)
        block.setContentWidth(CGFloat(cell.columnSpan) * 100 / CGFloat(table.numberOfColumns), type: .percentageValueType)
        block.setWidth(5, type: .absoluteValueType, for: .padding)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        block.verticalAlignment = .topAlignment
        block.setValue(fontSize + 2, type: .absoluteValueType, for: .minimumHeight)
        if case .element("th", _, _) = cell.node { block.backgroundColor = .quaternaryLabelColor }
        return block
    }
    /// Native table cells are paragraphs. Supply tab-separated columns for
    /// plain-text destinations while keeping AppKit's table data in RTF.
    static func plainText(_ value: NSAttributedString) -> String {
        let text = value.string as NSString
        var output = "", location = 0
        var previous: NSTextTableBlock?
        func block(at location: Int) -> NSTextTableBlock? {
            guard location < value.length else { return nil }
            return (value.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
        }
        while location < value.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            let current = block(at: location)
            if let current, previous?.table === current.table, previous?.startingRow != current.startingRow {
                output += String(repeating: "\t", count: current.startingColumn)
            }
            let content = text.substring(with: range)
            let end = NSMaxRange(range)
            if let current, content.hasSuffix("\n") {
                output += String(content.dropLast())
                let next = block(at: end)
                if let next, current.table === next.table, current.startingRow == next.startingRow, current.startingColumn != next.startingColumn {
                    output += String(repeating: "\t", count: max(1, next.startingColumn - current.startingColumn))
                } else if let next, current.table === next.table, current.startingRow == next.startingRow, current.startingColumn == next.startingColumn {
                    output += "\n"
                } else {
                    output += String(repeating: "\t", count: max(0, current.table.numberOfColumns - current.startingColumn - 1)) + "\n"
                }
            } else { output += content }
            previous = current
            location = end
        }
        return output
    }
}
