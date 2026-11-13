import Foundation
import Testing
@testable import RavenProtocol

struct AttachmentURLTests {
    let origin = URL(string: "https://site.test")!
    @Test func missingOrRootOnlyMetadataCannotResolveToAnAttachment() {
        for value in ["", "  ", "/", "./", "../", "?download=1", "#attachment", "https://site.test", "https://site.test/", "/folder/../", "/file\n.txt"] {
            #expect(throws: (any Error).self) { try RavenAttachmentURL.resolve(value, origin: origin) }
        }
    }
    @Test func attachmentLocationsRetainValidPrivatePathsAndQueries() throws {
        #expect(try RavenAttachmentURL.resolve("/private/files/report.pdf?download=1", origin: origin).path == "/private/files/report.pdf")
        #expect(try RavenAttachmentURL.resolve("/private/files/report.pdf?download=1", origin: origin).query == "download=1")
        #expect(try RavenAttachmentURL.resolve("https://SITE.test:443/files/report.txt", origin: origin).lastPathComponent == "report.txt")
    }
    @Test func attachmentsCannotCarryCredentialsOrEscapeTheAccountOrigin() {
        for value in ["https://other.test/files/a", "//other.test/files/a", "https://user:password@site.test/files/a", "http://site.test/files/a", "file:///private/a"] {
            #expect(throws: RavenError.crossOrigin) { try RavenAttachmentURL.resolve(value, origin: origin) }
        }
    }
}
