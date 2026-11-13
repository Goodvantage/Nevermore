import XCTest
@testable import NevermoreCore

final class LinkPreviewPolicyTests: XCTestCase {
    // MARK: - isEligible

    func testEligibleAddresses() {
        let eligible = [
            "https://example.com",
            "https://www.example.com/",
            "https://example.com/path?query=1#fragment",
            "https://example.com:443/",
            "https://sub.domain.co.uk/",
            "https://EXAMPLE.com/",
            "https://example.com./",
            "https://news.example.com/a/b/c",
        ]
        for string in eligible {
            guard let url = URL(string: string) else {
                return XCTFail("test URL did not parse: \(string)")
            }
            XCTAssertTrue(LinkPreviewPolicy.isEligible(url), string)
        }
    }

    func testSchemeIsCaseInsensitive() throws {
        XCTAssertTrue(LinkPreviewPolicy.isEligible(try XCTUnwrap(URL(string: "HTTPS://example.com/"))))
        XCTAssertFalse(LinkPreviewPolicy.isEligible(try XCTUnwrap(URL(string: "HTTP://example.com/"))))
    }

    func testIneligibleSchemes() {
        let ineligible = [
            "http://example.com/",
            "ftp://example.com/",
            "file:///etc/passwd",
            "mailto:user@example.com",
            "javascript:alert(1)",
            "https:example.com",
        ]
        for string in ineligible {
            guard let url = URL(string: string) else {
                return XCTFail("test URL did not parse: \(string)")
            }
            XCTAssertFalse(LinkPreviewPolicy.isEligible(url), string)
        }
    }

    func testIneligibleUserInfoAndPorts() {
        let ineligible = [
            "https://user@example.com/",
            "https://user:pass@example.com/",
            "https://example.com:8443/",
            "https://example.com:80/",
        ]
        for string in ineligible {
            guard let url = URL(string: string) else {
                return XCTFail("test URL did not parse: \(string)")
            }
            XCTAssertFalse(LinkPreviewPolicy.isEligible(url), string)
        }
    }

    func testIneligibleIPLiterals() {
        let ineligible = [
            "https://192.168.1.1/",
            "https://10.0.0.1/",
            "https://2130706433/",
            "https://0x7f.1/",
            "https://127.1/",
            "https://[::1]/",
            "https://[2001:db8::1]/",
            // A trailing dot makes a name fully qualified; it does not make
            // an address a name.
            "https://192.168.0.1./",
            "https://127.0.0.1./",
            "https://10.0.0.10./",
        ]
        for string in ineligible {
            guard let url = URL(string: string) else {
                return XCTFail("test URL did not parse: \(string)")
            }
            XCTAssertFalse(LinkPreviewPolicy.isEligible(url), string)
        }
    }

    func testIneligibleHostShapes() {
        let ineligible = [
            "https://localhost/",
            "https://example.1/",
            "https://example.c/",
            "https://foo.localhost/",
            "https://printer.local/",
            "https://router.internal/",
            "https://nas.lan/",
            "https://server.home/",
            "https://device.home.arpa/",
            "https://intranet.corp/",
            "https://wiki.intranet/",
            "https://vault.private/",
            "https://test.test/",
            "https://foo.invalid/",
            "https://abc.onion/",
        ]
        for string in ineligible {
            guard let url = URL(string: string) else {
                return XCTFail("test URL did not parse: \(string)")
            }
            XCTAssertFalse(LinkPreviewPolicy.isEligible(url), string)
        }
    }

    func testURLLengthBoundary() {
        let base = "https://example.com/"
        let fitting = base + String(repeating: "a", count: LinkPreviewPolicy.maximumURLLength - base.utf16.count)
        let tooLong = base + String(repeating: "a", count: LinkPreviewPolicy.maximumURLLength - base.utf16.count + 1)
        XCTAssertEqual(fitting.utf16.count, LinkPreviewPolicy.maximumURLLength)
        XCTAssertTrue(LinkPreviewPolicy.isEligible(URL(string: fitting)!))
        XCTAssertFalse(LinkPreviewPolicy.isEligible(URL(string: tooLong)!))
    }

    // MARK: - isPublic

    func testPublicIPv4Addresses() {
        let addresses: [LinkPreviewPolicy.Address] = [
            .v4(1, 1, 1, 1),
            .v4(8, 8, 8, 8),
            .v4(93, 184, 216, 34),
            .v4(11, 0, 0, 1),
            .v4(100, 63, 255, 255),
            .v4(100, 128, 0, 1),
            .v4(126, 255, 255, 255),
            .v4(128, 0, 0, 1),
            .v4(169, 253, 255, 255),
            .v4(169, 255, 0, 1),
            .v4(172, 15, 255, 255),
            .v4(172, 32, 0, 1),
            .v4(192, 0, 1, 255),
            .v4(192, 0, 3, 1),
            .v4(192, 167, 255, 255),
            .v4(192, 169, 0, 1),
            .v4(198, 17, 255, 255),
            .v4(198, 20, 0, 1),
            .v4(198, 51, 99, 255),
            .v4(198, 51, 101, 1),
            .v4(203, 0, 112, 255),
            .v4(203, 0, 114, 1),
            .v4(223, 255, 255, 255),
        ]
        for address in addresses {
            XCTAssertTrue(LinkPreviewPolicy.isPublic(address), "\(address)")
        }
    }

    func testNonPublicIPv4Ranges() {
        let ranges: [(LinkPreviewPolicy.Address, String)] = [
            (.v4(0, 0, 0, 0), "0.0.0.0/8"),
            (.v4(0, 255, 255, 255), "0.0.0.0/8"),
            (.v4(10, 0, 0, 0), "10/8"),
            (.v4(10, 255, 255, 255), "10/8"),
            (.v4(100, 64, 0, 0), "100.64/10"),
            (.v4(100, 127, 255, 255), "100.64/10"),
            (.v4(127, 0, 0, 1), "127/8"),
            (.v4(127, 255, 255, 255), "127/8"),
            (.v4(169, 254, 0, 1), "169.254/16"),
            (.v4(169, 254, 255, 255), "169.254/16"),
            (.v4(172, 16, 0, 1), "172.16/12"),
            (.v4(172, 31, 255, 255), "172.16/12"),
            (.v4(192, 0, 0, 1), "192.0.0.0/24"),
            (.v4(192, 0, 0, 255), "192.0.0.0/24"),
            (.v4(192, 0, 2, 1), "192.0.2.0/24"),
            (.v4(192, 88, 99, 1), "192.88.99.0/24"),
            (.v4(192, 168, 0, 1), "192.168/16"),
            (.v4(192, 168, 255, 255), "192.168/16"),
            (.v4(198, 18, 0, 1), "198.18/15"),
            (.v4(198, 19, 255, 255), "198.18/15"),
            (.v4(198, 51, 100, 1), "198.51.100/24"),
            (.v4(203, 0, 113, 1), "203.0.113/24"),
            (.v4(224, 0, 0, 1), "224/4"),
            (.v4(239, 255, 255, 255), "224/4"),
            (.v4(240, 0, 0, 0), "240/4"),
            (.v4(255, 255, 255, 255), "broadcast"),
        ]
        for (address, label) in ranges {
            XCTAssertFalse(LinkPreviewPolicy.isPublic(address), label)
        }
    }

    private func ipv6(_ groups: UInt16...) -> LinkPreviewPolicy.Address {
        var bytes: [UInt8] = []
        for group in groups {
            bytes.append(UInt8(group >> 8))
            bytes.append(UInt8(group & 0xff))
        }
        return .v6(bytes)
    }

    func testPublicIPv6Addresses() {
        let addresses: [LinkPreviewPolicy.Address] = [
            ipv6(0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111),
            ipv6(0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888),
            ipv6(0x3ffe, 0xffff, 0, 0, 0, 0, 0, 1),
            ipv6(0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 1),
            ipv6(0, 0, 0, 0, 0, 0xffff, 0x0808, 0x0808),
            ipv6(0x0064, 0xff9b, 0, 0, 0, 0, 0x0808, 0x0808),
        ]
        for address in addresses {
            XCTAssertTrue(LinkPreviewPolicy.isPublic(address), "\(address)")
        }
    }

    func testNonPublicIPv6Ranges() {
        let ranges: [(LinkPreviewPolicy.Address, String)] = [
            (ipv6(0, 0, 0, 0, 0, 0, 0, 0), "::"),
            (ipv6(0, 0, 0, 0, 0, 0, 0, 1), "::1"),
            (ipv6(0xfc00, 0, 0, 0, 0, 0, 0, 1), "fc00::/7"),
            (ipv6(0xfd12, 0, 0, 0, 0, 0, 0, 1), "fc00::/7"),
            (ipv6(0xfe80, 0, 0, 0, 0, 0, 0, 1), "fe80::/10"),
            (ipv6(0xfebf, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff), "fe80::/10"),
            (ipv6(0xff02, 0, 0, 0, 0, 0, 0, 1), "ff00::/8"),
            (ipv6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1), "2001:db8::/32"),
            (ipv6(0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0101), "IPv4-mapped private"),
            (ipv6(0, 0, 0, 0, 0, 0, 0x7f00, 0x0001), "IPv4-compatible loopback"),
            (ipv6(0xfbff, 0, 0, 0, 0, 0, 0, 1), "outside 2000::/3"),
            (ipv6(0xfec0, 0, 0, 0, 0, 0, 0, 1), "fec0::/10 site-local"),
            (ipv6(0x0100, 0, 0, 0, 0, 0, 0, 1), "100::/64 discard"),
            (ipv6(0x2001, 0, 0x4136, 0xe378, 0x8000, 0x63bf, 0x3fff, 0xfdd2), "2001::/32 Teredo"),
            (ipv6(0x2001, 0x0002, 0, 0, 0, 0, 0, 1), "2001:2::/48 benchmarking"),
            (ipv6(0x2002, 0xc0a8, 0x0101, 0, 0, 0, 0, 1), "6to4 private"),
            (ipv6(0x2002, 0x7f00, 0x0001, 0, 0, 0, 0, 1), "6to4 loopback"),
            (ipv6(0x3fff, 0x0abc, 0, 0, 0, 0, 0, 1), "3fff::/20 documentation"),
            (ipv6(0x0064, 0xff9b, 0, 0, 0, 0, 0xc0a8, 0x0101), "NAT64 private"),
            (.v6([0x00]), "one byte"),
            (.v6([UInt8](repeating: 0, count: 15)), "15 bytes"),
            (.v6([UInt8](repeating: 0, count: 17)), "17 bytes"),
        ]
        for (address, label) in ranges {
            XCTAssertFalse(LinkPreviewPolicy.isPublic(address), label)
        }
    }

    // MARK: - Content types

    func testAcceptsHTML() {
        XCTAssertTrue(LinkPreviewPolicy.acceptsHTML(contentType: "text/html"))
        XCTAssertTrue(LinkPreviewPolicy.acceptsHTML(contentType: "text/html; charset=utf-8"))
        XCTAssertTrue(LinkPreviewPolicy.acceptsHTML(contentType: "application/xhtml+xml"))
        XCTAssertTrue(LinkPreviewPolicy.acceptsHTML(contentType: "APPLICATION/XHTML+XML; charset=UTF-8"))
        XCTAssertTrue(LinkPreviewPolicy.acceptsHTML(contentType: " text/html ; q=1"))
        XCTAssertFalse(LinkPreviewPolicy.acceptsHTML(contentType: nil))
        XCTAssertFalse(LinkPreviewPolicy.acceptsHTML(contentType: "text/plain"))
        XCTAssertFalse(LinkPreviewPolicy.acceptsHTML(contentType: "application/json"))
        XCTAssertFalse(LinkPreviewPolicy.acceptsHTML(contentType: ""))
    }

    func testAcceptsImage() {
        for type in ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/heic"] {
            XCTAssertTrue(LinkPreviewPolicy.acceptsImage(contentType: type), type)
            XCTAssertTrue(LinkPreviewPolicy.acceptsImage(contentType: "\(type); charset=x"), type)
            XCTAssertTrue(LinkPreviewPolicy.acceptsImage(contentType: type.uppercased()), type)
        }
        XCTAssertFalse(LinkPreviewPolicy.acceptsImage(contentType: "image/svg+xml"))
        XCTAssertFalse(LinkPreviewPolicy.acceptsImage(contentType: nil))
        XCTAssertFalse(LinkPreviewPolicy.acceptsImage(contentType: "text/html"))
        XCTAssertFalse(LinkPreviewPolicy.acceptsImage(contentType: "image/bmp"))
    }
}
