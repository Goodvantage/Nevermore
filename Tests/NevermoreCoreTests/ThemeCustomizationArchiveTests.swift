import XCTest
@testable import NevermoreCore

final class ThemeCustomizationArchiveTests: XCTestCase {
    func testArchiveRoundTripsCustomizationsPerPreset() throws {
        var halloween = ThemeCustomization()
        halloween.accent = ThemeColor(0x33DD88)
        halloween.motifOpacity = 0.4
        var memphis = ThemeCustomization()
        memphis.displayFont = ThemeCustomization.systemDisplayFont
        let stored = try XCTUnwrap(ThemeCustomizationArchive.encode([.halloween: halloween, .memphis: memphis]))
        XCTAssertEqual(ThemeCustomizationArchive.decode(stored), [.halloween: halloween, .memphis: memphis])
        // Sorted keys keep the stored text stable from one save to the next.
        XCTAssertEqual(stored, ##"{"halloween":{"accent":"#33DD88","motifOpacity":0.4},"memphis":{"displayFont":""}}"##)
    }

    func testArchiveStoresNothingWhenNoPresetIsCustomized() {
        XCTAssertNil(ThemeCustomizationArchive.encode([:]))
        XCTAssertNil(ThemeCustomizationArchive.encode([.halloween: ThemeCustomization()]))
    }

    func testArchiveRecoversFromDamagedText() {
        XCTAssertEqual(ThemeCustomizationArchive.decode(nil), [:])
        XCTAssertEqual(ThemeCustomizationArchive.decode(""), [:])
        XCTAssertEqual(ThemeCustomizationArchive.decode("not json"), [:])
        XCTAssertEqual(ThemeCustomizationArchive.decode("[1, 2]"), [:])
        XCTAssertEqual(ThemeCustomizationArchive.decode(#"{"halloween": 7}"#), [:])
    }

    func testArchiveKeepsReadableEntriesBesideADamagedOne() {
        var expected = ThemeCustomization()
        expected.accent = ThemeColor(0x112233)
        let stored = ##"{"memphis": 7, "neonFun": [1], "halloween": {"accent": "#112233"}}"##
        XCTAssertEqual(ThemeCustomizationArchive.decode(stored), [.halloween: expected])
    }

    func testDecodingKeepsTheShapesItCanReadFromAList() throws {
        let json = ##"""
        {"motifs":[{"motif":"unicorn","colors":["#000000"],"style":"fill","weight":2},
                   {"motif":"dot","colors":["#101010"],"style":"fill","weight":2}],
         "ornaments":[{"kind":"moonLarge","anchor":"top","colors":["#202020"],"opacity":0.5},
                      {"kind":"deathStar","anchor":"top","colors":["#000000"],"opacity":0.5},
                      7]}
        """##
        let decoded = try JSONDecoder().decode(ThemeCustomization.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.motifs, [MotifSpec(.dot, [ThemeColor(0x101010)], style: .fill, weight: 2)])
        XCTAssertEqual(decoded.ornaments, [OrnamentSpec(.moonLarge, .top, [ThemeColor(0x202020)], opacity: 0.5)])
    }

    func testAListWithNothingUsableFallsBackToThePreset() throws {
        // No art is the user's choice and stays; a list that lost every
        // entry it had is damage, and the preset's art returns.
        let json = ##"{"motifs":[{"motif":"unicorn","colors":["#000000"],"style":"fill","weight":2}],"ornaments":[]}"##
        let decoded = try JSONDecoder().decode(ThemeCustomization.self, from: Data(json.utf8))
        XCTAssertNil(decoded.motifs)
        XCTAssertEqual(decoded.ornaments, [])

        var custom = ThemeCustomization()
        custom.motifs = []
        custom.ornaments = [OrnamentSpec(.moonLarge, .top, [], opacity: 0.5)]
        XCTAssertEqual(custom.sanitized.motifs, [])
        XCTAssertNil(custom.sanitized.ornaments)
        let applied = ThemeCatalog.halloween.applying(custom)
        XCTAssertTrue(applied.wallpaper.motifs.isEmpty)
        XCTAssertEqual(applied.wallpaper.ornaments, ThemeCatalog.halloween.wallpaper.ornaments)
    }

    func testArchiveSkipsUnknownPresetsAndNormalizesTheRest() throws {
        let preset = try XCTUnwrap(ThemeCatalog.halloween.palette)
        let stored = """
        {"a-theme-from-the-future":{"accent":"#112233"},
         "classic":{"accent":"#112233"},
         "memphis":{"accent":"oops"},
         "halloween":{"accent":"#112233","link":"\(preset.link.hex)","sidebarTintOpacity":4,"nameColors":[]}}
        """
        var expected = ThemeCustomization()
        expected.accent = ThemeColor(0x112233)
        // The preset's own link is no edit, the opacity is clamped and the
        // empty name list is dropped.
        expected.sidebarTintOpacity = 1
        XCTAssertEqual(ThemeCustomizationArchive.decode(stored), [.halloween: expected])
    }
}
