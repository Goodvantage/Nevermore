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
    @Test func dotSegmentsCannotRedirectACredentialedFetch() {
        // URL parsing resolves literal `..`/`.` away at parse time and keeps
        // encoded traversal percent-encoded; both must be rejected so the wire
        // path can never escape the path the metadata named.
        for value in [
            "/files/../../etc/passwd", "/files/./x", "/files/.", "/files/..", "/files/a/./b",
            "..%2f..%2fetc", "%2e%2e", "/files/%2e/x", "/files/%2e%2e/%2e%2e/private/secret",
            "/files/%2E%2E/x", "/files/%2e%2e%2fsecret", "/files/a%2f..%2fb",
            "https://site.test/files/%2e%2e/x", "https://site.test/a/../b",
            "/files/%252e%252e/x", "/files/a%252f..%252fb", "%252e%252e", "/files/%25252e/x",
            "/files/..%5c..%5csecret", "/files\\..\\secret",
            // A malformed escape must not suppress decoding of valid ones.
            "/files/%2e%2e/%zz", "/files/%zz/%2e%2e", "/files/%2e%2e/%41%zz",
            // `;` matrix parameters are stripped before dot resolution on some
            // stacks, and compatibility characters decompose to ASCII dots.
            "/files/..;/secret", "/files/.;/secret", "/files/..%3b/secret",
            "/files/\u{FF0E}\u{FF0E}/x", "/files/\u{2025}/x", "/files/%ef%bc%8e%ef%bc%8e/x",
            // Junk some stacks strip before resolving dots — NUL, trailing
            // space, replacement chars from overlong UTF-8 — must not hide a
            // dot segment. `...` is traversal on Windows.
            "/files/..%00/secret", "/files/..%20/secret", "/files/.../secret",
            "/files/..%2e/x", "/files/..%c0%ae/x", "/files/. ./x",
            // A segment of nothing but strippable characters could decode to
            // dots on a server that overlong-decodes; it is no valid filename.
            "/files/%c0%ae%c0%ae/x", "/files/%20%20/x",
        ] {
            #expect(throws: (any Error).self) { try RavenAttachmentURL.resolve(value, origin: origin) }
        }
        // A dot surfacing only past the decode budget must fail closed, not
        // pass because the path is pathological rather than proven clean.
        let layer = String(repeating: "25", count: 16)
        #expect(throws: (any Error).self) { try RavenAttachmentURL.resolve("/files/%\(layer)2e/x.png", origin: origin) }
    }
    @Test func attachmentLocationsRetainValidPrivatePathsAndQueries() throws {
        #expect(try RavenAttachmentURL.resolve("/private/files/report.pdf?download=1", origin: origin).path == "/private/files/report.pdf")
        #expect(try RavenAttachmentURL.resolve("/private/files/report.pdf?download=1", origin: origin).query == "download=1")
        #expect(try RavenAttachmentURL.resolve("https://SITE.test:443/files/report.txt", origin: origin).lastPathComponent == "report.txt")
        // Dots inside a segment are ordinary filename characters, not traversal.
        #expect(try RavenAttachmentURL.resolve("/files/report..final.pdf", origin: origin).lastPathComponent == "report..final.pdf")
        #expect(try RavenAttachmentURL.resolve("/files/v2.0/spec.pdf", origin: origin).lastPathComponent == "spec.pdf")
        // Traversal-shaped text in the query is data, not path segments.
        #expect(try RavenAttachmentURL.resolve("/files/ok.png?returnTo=/up/../down", origin: origin).query == "returnTo=/up/../down")
        // A percent sign in a filename is not an encoding layer.
        #expect(try RavenAttachmentURL.resolve("/files/100%25/report.pdf", origin: origin).lastPathComponent == "report.pdf")
        // Dots glued to junk are a filename, not a segment.
        #expect(try RavenAttachmentURL.resolve("/files/%2e%2e%zz/x.png", origin: origin).lastPathComponent == "x.png")
    }
    @Test func attachmentsCannotCarryCredentialsOrEscapeTheAccountOrigin() {
        for value in ["https://other.test/files/a", "//other.test/files/a", "https://user:password@site.test/files/a", "http://site.test/files/a", "file:///private/a"] {
            #expect(throws: RavenError.crossOrigin) { try RavenAttachmentURL.resolve(value, origin: origin) }
        }
    }
}
