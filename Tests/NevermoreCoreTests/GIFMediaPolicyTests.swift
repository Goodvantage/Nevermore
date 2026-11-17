import XCTest
@testable import NevermoreCore

final class GIFMediaPolicyTests: XCTestCase {
    func testAcceptsGIFServiceMediaHosts() {
        for address in ["https://media.tenor.com/abc/dance.gif", "https://media2.giphy.com/media/x/giphy.gif", "https://i.giphy.com/x.webp", "https://static.klipy.com/a/b.gif", "https://giphy.com/x.gif", "https://MEDIA.TENOR.COM/abc.gif"] {
            XCTAssertNotNil(GIFMediaPolicy.mediaURL(address), address)
        }
    }

    func testRejectsEverythingElse() {
        for address in [
            "http://media.tenor.com/abc.gif",          // not HTTPS
            "https://tracker.example/p.gif",            // not a GIF service
            "https://notgiphy.com/x.gif",               // lookalike domain
            "https://giphy.com.evil.example/x.gif",     // service name as a label
            "https://media.tenor.com:8443/abc.gif",     // odd port
            "https://user:pw@media.tenor.com/abc.gif",  // credentials
            "/files/local.gif",                         // relative site file
            "javascript:alert(1)",
            "",
        ] {
            XCTAssertNil(GIFMediaPolicy.mediaURL(address), address)
        }
        XCTAssertNil(GIFMediaPolicy.mediaURL("https://media.tenor.com/" + String(repeating: "a", count: LinkPreviewPolicy.maximumURLLength)))
    }

    func testGIFsInMessagesDefaultToOn() {
        XCTAssertTrue(GIFPreferences.showsInMessages(storedValue: nil))
        XCTAssertTrue(GIFPreferences.showsInMessages(storedValue: "garbage"))
        XCTAssertFalse(GIFPreferences.showsInMessages(storedValue: false))
        XCTAssertTrue(GIFPreferences.showsInMessages(storedValue: true))
    }
}
