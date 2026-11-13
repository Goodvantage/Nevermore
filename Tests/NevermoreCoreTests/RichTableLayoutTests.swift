import Testing
@testable import NevermoreCore

struct RichTableLayoutTests {
    private func layout(_ html: String) throws -> RichTableLayout? {
        try RichTextCodec.parse(html).nodes.first.flatMap(RichTableLayout.init)
    }
    @Test func rectangularTablesRetainHeaderAndBodyPositions() throws {
        let table = try #require(try layout("<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>C</td><td>D</td></tr></tbody></table>"))
        #expect(table.rows == 2 && table.columns == 2)
        #expect(table.cells.map(\.row) == [0, 0, 1, 1])
        #expect(table.cells.map(\.column) == [0, 1, 0, 1])
        #expect(table.cells.first?.node == .element("th", [:], [.text("A")]))
    }
    @Test func spansReserveAllCoveredRowsAndColumns() throws {
        let table = try #require(try layout("<table><tr><td rowspan=2>A</td><td colspan=2>B</td></tr><tr><td>C</td><td>D</td></tr></table>"))
        #expect(table.columns == 3 && table.rows == 2)
        #expect(table.cells.map(\.column) == [0, 1, 1, 2])
        #expect(table.cells[0].rowSpan == 2 && table.cells[1].columnSpan == 2)
    }
    @Test func overlappingIncompleteAndNestedShapesUseCompleteFallback() throws {
        #expect(try layout("<table><tr><td>A</td><td rowspan=2>B</td></tr><tr><td colspan=2>C</td></tr></table>") == nil)
        #expect(try layout("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td></tr></table>") == nil)
        #expect(try layout("<table><tr><td><table><tr><td>nested</td></tr></table></td></tr></table>") == nil)
        #expect(try layout("<table><tbody data-spoiler=true><tr><td>secret</td></tr></tbody></table>") == nil)
    }
    @Test func layoutWorkIsBoundedWithoutTruncatingTheSource() throws {
        let wide = "<table><tr>" + String(repeating: "<td>value</td>", count: 21) + "</tr></table>"
        let tall = "<table>" + String(repeating: "<tr><td>value</td></tr>", count: 51) + "</table>"
        #expect(try layout(wide) == nil && layout(tall) == nil)
        var deep = RichNode.text("value")
        for _ in 0..<40 { deep = .element("span", [:], [deep]) }
        #expect(RichTableLayout(.element("table", [:], [.element("tr", [:], [.element("td", [:], [deep])])])) == nil)
        let oversizedContent = RichNode.element("table", [:], [.element("tr", [:], [.element("td", [:], Array(repeating: .text("v"), count: 10_001))])])
        #expect(RichTableLayout(oversizedContent) == nil)
        let doc = try RichTextCodec.parse(wide)
        #expect(!doc.canEdit && RichTextCodec.html(doc).components(separatedBy: "value").count == 22)
    }
}
