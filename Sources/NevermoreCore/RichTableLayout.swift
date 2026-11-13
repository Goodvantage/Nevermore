import Foundation

/// Bounded table geometry for native reading. Unsupported or malformed shapes
/// retain their complete text fallback and remain protected from native editing.
public struct RichTableLayout: Sendable {
    public struct Cell: Sendable {
        public let node: RichNode
        public let row: Int
        public let column: Int
        public let rowSpan: Int
        public let columnSpan: Int
        public var alignment: RichTableAlignment? { RichTableStyle.alignment(node) }
    }
    public let rows: Int
    public let columns: Int
    public let cells: [Cell]
    private static let maximumRows = 50
    private static let maximumColumns = 20

    public init?(_ node: RichNode) {
        guard case .element("table", let attributes, let children) = node, attributes["data-spoiler"] == nil else { return nil }
        var rowNodes: [[RichNode]] = []
        var declaredColumns: Int?
        func collect(_ nodes: [RichNode], allowsGroups: Bool) -> Bool {
            for child in nodes {
                if case .text(let text) = child, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard case .element(let tag, let fields, let content) = child, fields["data-spoiler"] == nil else { return false }
                if allowsGroups, tag == "colgroup" {
                    guard declaredColumns == nil else { return false }
                    let columns = content.filter { if case .text(let text) = $0 { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; return true }
                    guard !columns.isEmpty, columns.count <= Self.maximumColumns, columns.allSatisfy({
                        if case .element("col", let fields, let children) = $0 { return fields["data-spoiler"] == nil && children.isEmpty }
                        return false
                    }) else { return false }
                    declaredColumns = columns.count
                } else if tag == "tr" {
                    guard rowNodes.count < Self.maximumRows else { return false }
                    rowNodes.append(content)
                } else if allowsGroups, ["thead", "tbody", "tfoot"].contains(tag) {
                    guard collect(content, allowsGroups: false) else { return false }
                } else { return false }
            }
            return true
        }
        var remainingContentNodes = 10_000
        func unsupportedContent(_ node: RichNode, depth: Int = 0) -> Bool {
            guard remainingContentNodes > 0, depth <= 32 else { return true }
            remainingContentNodes -= 1
            guard case .element(let tag, _, let children) = node else { return false }
            return tag == "table" || children.contains { unsupportedContent($0, depth: depth + 1) }
        }
        guard collect(children, allowsGroups: true), !rowNodes.isEmpty else { return nil }
        var occupied = Array(repeating: Array(repeating: false, count: Self.maximumColumns), count: rowNodes.count)
        var result: [Cell] = [], columnCount = 0
        for (row, nodes) in rowNodes.enumerated() {
            var column = 0, cellCount = 0
            for node in nodes {
                if case .text(let text) = node, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                guard case .element(let tag, let fields, let children) = node, ["td", "th"].contains(tag), !children.contains(where: { unsupportedContent($0) }),
                      let rowSpan = Int(fields["rowspan"] ?? "1"), let columnSpan = Int(fields["colspan"] ?? "1"),
                      rowSpan > 0, rowSpan <= rowNodes.count - row, columnSpan > 0, columnSpan <= Self.maximumColumns else { return nil }
                while column < Self.maximumColumns, occupied[row][column] { column += 1 }
                guard column <= Self.maximumColumns - columnSpan else { return nil }
                for r in row..<(row + rowSpan) {
                    for c in column..<(column + columnSpan) {
                        guard !occupied[r][c] else { return nil }
                        occupied[r][c] = true
                    }
                }
                result.append(Cell(node: node, row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan))
                cellCount += 1; column += columnSpan; columnCount = max(columnCount, column)
            }
            guard cellCount > 0 || occupied[row].contains(true) else { return nil }
        }
        guard columnCount > 0, declaredColumns.map({ $0 == columnCount }) ?? true,
              occupied.allSatisfy({ $0.prefix(columnCount).allSatisfy { $0 } }) else { return nil }
        rows = rowNodes.count; columns = columnCount; cells = result
    }
}
