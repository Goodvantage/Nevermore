import Foundation

public enum RichTableEditingError: LocalizedError {
    case invalidTable, invalidCell, boundary, mergedGeometry, lastCell, limit
    public var errorDescription: String? {
        switch self {
        case .invalidTable: "This table cannot be edited safely. Its original layout is preserved."
        case .invalidCell: "This cell contains unsupported formatting. Its original content is preserved."
        case .boundary: "Choose a cell inside the table."
        case .mergedGeometry: "Row and column changes require an unmerged table. You can still edit the text in merged cells."
        case .lastCell: "A table must have at least one row and one column."
        case .limit: "Tables can contain up to 50 rows and 20 columns."
        }
    }
}

/// Bounded, transactional table edits. Every mutation is validated before the
/// value changes. Cell edits preserve spans and row groups; geometry operations
/// deliberately refuse merged tables rather than guessing how to split them.
public struct EditableRichTable: Sendable {
    public private(set) var node: RichNode
    public private(set) var layout: RichTableLayout

    public init(_ node: RichNode) throws {
        guard let layout = RichTableLayout(node) else { throw RichTableEditingError.invalidTable }
        let checked = try RichTextCodec.parse(RichTextCodec.html(RichDocument(nodes: [node])))
        guard checked.canEdit, checked.nodes.count == 1,
              Self.normalized(node) == Self.normalized(checked.nodes[0]) else { throw RichTableEditingError.invalidTable }
        self.node = node; self.layout = layout
    }

    public static func make(rows: Int, columns: Int) throws -> Self {
        guard (1...50).contains(rows), (1...20).contains(columns) else { throw RichTableEditingError.limit }
        let children: [RichNode] = (0..<rows).map { row in
            .element("tr", [:], (0..<columns).map { _ in .element(row == 0 ? "th" : "td", [:], [.element("p", [:], [])]) })
        }
        return try Self(.element("table", [:], [.element("tbody", [:], children)]))
    }

    public func cell(row: Int, column: Int) -> RichNode? { owner(row: row, column: column)?.node }

    public mutating func replaceCell(row: Int, column: Int, content: [RichNode]) throws {
        guard let owner = owner(row: row, column: column) else { throw RichTableEditingError.boundary }
        let document = try RichTextCodec.parse(RichTextCodec.html(RichDocument(nodes: content)))
        // A raw RichNode can otherwise contain an unknown tag which the HTML
        // writer strips. Equality checks that validation did not remove it.
        guard document.canEdit, document.nodes == content, !content.contains(where: Self.containsTable) else { throw RichTableEditingError.invalidCell }
        let rows = rowPaths()
        let siblings = layout.cells.filter { $0.row == owner.row }
        guard let index = siblings.firstIndex(where: { $0.column == owner.column }), case .element(let tag, let attrs, _) = owner.node else { throw RichTableEditingError.invalidTable }
        let rowNode = Self.at(rows[owner.row], in: node)
        let indices = Self.cellIndices(rowNode)
        let path = rows[owner.row] + [indices[index]]
        try commit(Self.replacing(path, in: node, with: .element(tag, attrs, content)))
    }

    public mutating func insertRow(at index: Int) throws {
        try requireUnmerged()
        guard index >= 0, index <= layout.rows else { throw RichTableEditingError.boundary }
        guard layout.rows < 50 else { throw RichTableEditingError.limit }
        let paths = rowPaths(), neighbour = paths[min(index, paths.count - 1)]
        let insertion = neighbour.last! + (index == paths.count ? 1 : 0)
        let parent = Array(neighbour.dropLast())
        let cells = Self.at(neighbour, in: node).children.compactMap { cell -> RichNode? in
            guard case .element(let tag, let attrs, _) = cell, ["th", "td"].contains(tag) else { return nil }
            return .element(tag, attrs.filter { $0.key == "colwidth" }, [.element("p", [:], [])])
        }
        let changed = Self.changingChildren(Self.at(parent, in: node)) { $0.insert(.element("tr", [:], cells), at: insertion) }
        try commit(Self.replacing(parent, in: node, with: changed))
    }

    public mutating func removeRow(at index: Int) throws {
        try requireUnmerged()
        guard index >= 0, index < layout.rows else { throw RichTableEditingError.boundary }
        guard layout.rows > 1 else { throw RichTableEditingError.lastCell }
        let path = rowPaths()[index], parent = Array(path.dropLast())
        let changed = Self.changingChildren(Self.at(parent, in: node)) { $0.remove(at: path.last!) }
        try commit(Self.replacing(parent, in: node, with: changed))
    }

    public mutating func insertColumn(at index: Int) throws {
        try requireUnmerged()
        guard index >= 0, index <= layout.columns else { throw RichTableEditingError.boundary }
        guard layout.columns < 20 else { throw RichTableEditingError.limit }
        var changed = node
        for path in rowPaths() {
            let row = Self.at(path, in: changed), indices = Self.cellIndices(row)
            let neighbour = indices[min(index, indices.count - 1)]
            guard case .element(let tag, let attrs, _) = row.children[neighbour] else { throw RichTableEditingError.invalidTable }
            let insertion = neighbour + (index == indices.count ? 1 : 0)
            let replacement = Self.changingChildren(row) { $0.insert(.element(tag, attrs.filter { $0.key == "colwidth" }, [.element("p", [:], [])]), at: insertion) }
            changed = Self.replacing(path, in: changed, with: replacement)
        }
        try commit(Self.changingColumnMetadata(changed, at: index, operation: .insert))
    }

    public mutating func removeColumn(at index: Int) throws {
        try requireUnmerged()
        guard index >= 0, index < layout.columns else { throw RichTableEditingError.boundary }
        guard layout.columns > 1 else { throw RichTableEditingError.lastCell }
        var changed = node
        for path in rowPaths() {
            let row = Self.at(path, in: changed), indices = Self.cellIndices(row)
            let replacement = Self.changingChildren(row) { $0.remove(at: indices[index]) }
            changed = Self.replacing(path, in: changed, with: replacement)
        }
        try commit(Self.changingColumnMetadata(changed, at: index, operation: .remove))
    }

    private enum ColumnOperation { case insert, remove }
    private static func changingColumnMetadata(_ node: RichNode, at index: Int, operation: ColumnOperation) throws -> RichNode {
        guard case .element("table", var attrs, var children) = node,
              let groupIndex = children.firstIndex(where: { if case .element("colgroup", _, _) = $0 { return true }; return false }),
              case .element("colgroup", let groupAttrs, var columns) = children[groupIndex] else { return node }
        let positions = columns.indices.filter { if case .element("col", _, _) = columns[$0] { return true }; return false }
        switch operation {
        case .insert:
            let neighbour = positions[min(index, positions.count - 1)]
            guard case .element("col", let columnAttrs, _) = columns[neighbour] else { throw RichTableEditingError.invalidTable }
            columns.insert(.element("col", columnAttrs.filter { $0.key == "style" }, []), at: neighbour + (index == positions.count ? 1 : 0))
        case .remove: columns.remove(at: positions[index])
        }
        children[groupIndex] = .element("colgroup", groupAttrs, columns)
        if attrs["style"] != nil {
            let columnNodes = columns.filter { if case .element("col", _, _) = $0 { return true }; return false }
            guard let width = RichTableStyle.totalWidth(of: columnNodes) else { throw RichTableEditingError.invalidTable }
            attrs["style"] = width
        }
        return .element("table", attrs, children)
    }

    // HTML parsers insert a tbody around direct rows. That is the only
    // normalization allowed here; unknown tags/attributes must not vanish.
    private static func normalized(_ node: RichNode) -> RichNode {
        guard case .element(let tag, let attrs, let children) = node else { return node }
        let content = children.flatMap { child -> [RichNode] in
            if tag == "table", case .element("tbody", let attrs, let rows) = child, attrs.isEmpty { return rows.map(normalized) }
            return [normalized(child)]
        }
        return .element(tag, attrs, content)
    }

    private func owner(row: Int, column: Int) -> RichTableLayout.Cell? {
        layout.cells.first { ($0.row..<($0.row + $0.rowSpan)).contains(row) && ($0.column..<($0.column + $0.columnSpan)).contains(column) }
    }
    private func requireUnmerged() throws {
        guard layout.cells.allSatisfy({ $0.rowSpan == 1 && $0.columnSpan == 1 }) else { throw RichTableEditingError.mergedGeometry }
    }
    private mutating func commit(_ node: RichNode) throws { self = try Self(node) }
    private static func containsTable(_ node: RichNode) -> Bool {
        if case .element("table", _, _) = node { return true }
        return node.children.contains(where: containsTable)
    }
    private func rowPaths() -> [[Int]] {
        var result: [[Int]] = []
        func visit(_ node: RichNode, path: [Int]) {
            if case .element("tr", _, _) = node { result.append(path); return }
            for (index, child) in node.children.enumerated() { visit(child, path: path + [index]) }
        }
        visit(node, path: []); return result
    }
    private static func cellIndices(_ node: RichNode) -> [Int] {
        node.children.indices.filter { if case .element(let tag, _, _) = node.children[$0] { return ["td", "th"].contains(tag) }; return false }
    }
    private static func at(_ path: [Int], in node: RichNode) -> RichNode { path.reduce(node) { $0.children[$1] } }
    private static func changingChildren(_ node: RichNode, _ change: (inout [RichNode]) -> Void) -> RichNode {
        guard case .element(let tag, let attrs, var children) = node else { return node }
        change(&children); return .element(tag, attrs, children)
    }
    private static func replacing(_ path: [Int], in node: RichNode, with replacement: RichNode) -> RichNode {
        guard let first = path.first else { return replacement }
        return changingChildren(node) { $0[first] = replacing(Array(path.dropFirst()), in: $0[first], with: replacement) }
    }
}
