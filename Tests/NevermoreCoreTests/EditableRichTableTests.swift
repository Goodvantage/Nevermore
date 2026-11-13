import Testing
@testable import NevermoreCore

struct EditableRichTableTests {
    private func table(_ html: String) throws -> EditableRichTable {
        try EditableRichTable(#require(RichTextCodec.parse(html).nodes.first))
    }

    @Test func insertRemoveRowsAndColumnsPreserveCells() throws {
        var value = try table("<table title='T'><thead title='Head'><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td><strong>C</strong></td><td>D</td></tr></tbody></table>")
        let original = value.node
        try value.insertRow(at: 1)
        #expect(value.layout.rows == 3)
        #expect(value.cell(row: 2, column: 0)?.children == [.element("strong", [:], [.text("C")])])
        try value.removeRow(at: 1)
        #expect(value.node == original)
        try value.insertColumn(at: 1)
        #expect(value.layout.columns == 3)
        #expect(value.cell(row: 1, column: 2)?.children == [.text("D")])
        try value.removeColumn(at: 1)
        #expect(value.node == original)
        try value.insertRow(at: value.layout.rows)
        try value.insertColumn(at: value.layout.columns)
        #expect(value.layout.rows == 3 && value.layout.columns == 3)
    }

    @Test func mergedCellContentPreservesSpansAndIdentity() throws {
        var value = try table("<table><tr><td rowspan='2' title='merged'>A</td><td>B</td></tr><tr><td>C</td></tr></table>")
        let content = try RichTextCodec.parse(#"<p><span data-spoiler="true"><span data-type="userMention" data-id="uid">@Person</span></span></p>"#).nodes
        try value.replaceCell(row: 1, column: 0, content: content)
        guard case .element("td", let attrs, let children) = value.cell(row: 0, column: 0) else { Issue.record("Missing merged cell"); return }
        #expect(attrs == ["rowspan": "2", "title": "merged"])
        #expect(children == content)
        #expect(value.cell(row: 1, column: 1)?.children == [.text("C")])
        let before = value.node
        #expect(throws: (any Error).self) { try value.insertRow(at: 1) }
        #expect(throws: (any Error).self) { try value.removeColumn(at: 0) }
        #expect(value.node == before)
    }

    @Test func cellsCanContainRichListsQuotesAndCode() throws {
        var value = try EditableRichTable.make(rows: 1, columns: 1)
        let content = try RichTextCodec.parse("<ul><li><strong>item</strong></li></ul><blockquote><p>quote</p></blockquote><pre><code>code</code></pre>").nodes
        try value.replaceCell(row: 0, column: 0, content: content)
        #expect(value.cell(row: 0, column: 0)?.children == content)
        #expect(try RichTextCodec.parse(RichTextCodec.html(RichDocument(nodes: [value.node]))).canEdit)
    }

    @Test func invalidOperationsAreAtomic() throws {
        var value = try EditableRichTable.make(rows: 1, columns: 1)
        let before = value.node
        #expect(throws: (any Error).self) { try value.removeRow(at: 0) }
        #expect(throws: (any Error).self) { try value.removeColumn(at: 0) }
        #expect(throws: (any Error).self) { try value.insertRow(at: -1) }
        #expect(throws: (any Error).self) { try value.insertColumn(at: 2) }
        #expect(throws: (any Error).self) { try value.replaceCell(row: 1, column: 0, content: [.text("bad")]) }
        #expect(throws: (any Error).self) { try value.replaceCell(row: 0, column: 0, content: [.element("script", [:], [.text("bad")])]) }
        #expect(throws: (any Error).self) { try value.replaceCell(row: 0, column: 0, content: [before]) }
        #expect(value.node == before)
    }

    @Test func columnGeometryKeepsRavenSizingMetadataConsistent() throws {
        var value = try table(#"<table style="min-width: 105px"><colgroup><col style="min-width: 25px"><col style="width: 80px"></colgroup><tbody><tr><th>A</th><th colwidth="80" style="text-align: right">B</th></tr></tbody></table>"#)
        let original = value.node
        try value.replaceCell(row: 0, column: 1, content: [.text("updated")])
        guard case .element(_, let attrs, _) = value.cell(row: 0, column: 1) else { Issue.record("Missing cell"); return }
        #expect(attrs["colwidth"] == "80" && attrs["style"] == "text-align: right")
        try value.replaceCell(row: 0, column: 1, content: [.text("B")])
        try value.insertColumn(at: 1)
        #expect(value.layout.columns == 3)
        #expect(RichTextCodec.html(RichDocument(nodes: [value.node])).contains("min-width: 185px"))
        try value.removeColumn(at: 1)
        #expect(value.node == original)
        try value.insertRow(at: 1)
        guard case .element(_, let added, _) = value.cell(row: 1, column: 1) else { Issue.record("Missing inserted cell"); return }
        #expect(added["colwidth"] == "80")
    }

    @Test func unsupportedRawNodesCannotBeSilentlyNormalized() {
        let cell = RichNode.element("td", [:], [.element("script", [:], [.text("lost")])])
        let table = RichNode.element("table", [:], [.element("tr", [:], [cell])])
        #expect(throws: (any Error).self) { try EditableRichTable(table) }
        let styled = RichNode.element("table", ["style": "width:50%"], [.element("tr", [:], [.element("td", [:], [.text("A")])])])
        #expect(throws: (any Error).self) { try EditableRichTable(styled) }
    }

    @Test func sizeLimitsAndMalformedGeometryAreRejected() throws {
        #expect(throws: (any Error).self) { try EditableRichTable.make(rows: 51, columns: 1) }
        #expect(throws: (any Error).self) { try EditableRichTable.make(rows: 1, columns: 21) }
        #expect(throws: (any Error).self) { try EditableRichTable.make(rows: 0, columns: 1) }
        #expect(throws: (any Error).self) { try table("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td></tr></table>") }
    }
}
