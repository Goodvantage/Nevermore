import Testing
@testable import NevermoreCore

struct RichTableEditingBoundaryTests {
    @Test func boundedTablesCanBeEdited() throws {
        for html in [
            "<table><tr><th>A</th><th>B</th></tr><tr><td><p><strong>C</strong></p></td><td>D</td></tr></table>",
            "<table><tr><td rowspan=2>A</td><td>B</td></tr><tr><td>C</td></tr></table>"
        ] {
            let document = try RichTextCodec.parse(html)
            #expect(document.canEdit)
            #expect(try RichTextCodec.parse(RichTextCodec.html(document)).nodes == document.nodes)
        }
    }

    @Test func ravenEditorColumnMetadataIsEditableAndPreserved() throws {
        let html = #"<table style="min-width: 50px"><colgroup><col style="min-width: 25px"><col style="width: 80px"></colgroup><tbody><tr><th colspan="1" rowspan="1"><p>A</p></th><th colwidth="80" style="text-align: right"><p>B</p></th></tr></tbody></table>"#
        let document = try RichTextCodec.parse(html)
        #expect(document.canEdit)
        let encoded = RichTextCodec.html(document)
        #expect(encoded.contains("<colgroup>"))
        #expect(encoded.contains("style=\"min-width: 50px\""))
        #expect(encoded.contains("colwidth=\"80\""))
        #expect(encoded.contains("style=\"text-align: right\""))
        #expect(try RichTextCodec.parse(encoded).nodes == document.nodes)
    }

    @Test func malformedOrUnsupportedTablesStayProtected() throws {
        for html in [
            "<table><tr><td>A</td><td>B</td></tr><tr><td>C</td></tr></table>",
            "<table><tr><td rowspan=0>A</td></tr></table>",
            "<table><tr><td colspan=101>A</td></tr></table>",
            "<table><tr><td><table><tr><td>A</td></tr></table></td></tr></table>",
            "<blockquote><table><tr><td>A</td></tr></table></blockquote>",
            "<table style='width: 80%'><tr><td>A</td></tr></table>",
            "<table style='width: url(https://bad.example)'><tr><td>A</td></tr></table>",
            "<table style='width: 20px; background: red'><tr><td>A</td></tr></table>",
            "<table><colgroup><col style='width: 20px'><col></colgroup><tr><td>A</td></tr></table>",
            "<table><tr><td colwidth='999999999999'>A</td></tr></table>",
            "<table><tr><td colwidth='10,20'>A</td></tr></table>",
            "<table><tr><td style='text-align: justify'>A</td></tr></table>"
        ] {
            #expect(try !RichTextCodec.parse(html).canEdit)
        }
    }
}
