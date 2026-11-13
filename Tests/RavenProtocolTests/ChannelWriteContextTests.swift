import Foundation
import Testing
@testable import RavenProtocol

extension TransportSuite {
    @Test func canonicalThreadWriteContextChecksTheParentsArchiveFlag() async throws {
        let session = StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/resource/Raven Channel/thread": return stubResponse(request, 200, #"{"data":{"name":"thread","channel_name":"root","is_thread":1,"is_archived":0}}"#)
            case "/api/resource/Raven Message/root": return stubResponse(request, 200, #"{"data":{"name":"root","channel_id":"parent"}}"#)
            case "/api/resource/Raven Channel/parent": return stubResponse(request, 200, #"{"data":{"name":"parent","is_thread":0,"is_archived":1}}"#)
            default: Issue.record("Unexpected canonical context request"); return stubResponse(request, 500, "{}")
            }
        }
        let context = try await client(session).channelWriteContext("thread")
        #expect(context.isArchived && context.archivedChannelID == "parent")
        #expect(context.parentChannelIDs == ["parent"])
    }
    @Test func attachmentReadsCheckParentsEvenWhenTheThreadIsArchived() async throws {
        let session = StubURLProtocol.install { request in
            switch request.url!.path {
            case "/api/resource/Raven Channel/thread": return stubResponse(request, 200, #"{"data":{"name":"thread","channel_name":"root","is_thread":1,"is_archived":1}}"#)
            case "/api/resource/Raven Message/root": return stubResponse(request, 200, #"{"data":{"name":"root","channel_id":"parent"}}"#)
            case "/api/resource/Raven Channel/parent": return stubResponse(request, 200, #"{"data":{"name":"parent","is_thread":0,"is_archived":0}}"#)
            default: Issue.record("Unexpected attachment permission request"); return stubResponse(request, 500, "{}")
            }
        }
        let context = try await client(session).channelReadContext("thread")
        #expect(context.parentChannelIDs == ["parent"] && context.archivedChannelID == "thread")
        let denied = StubURLProtocol.install { request in
            if request.url!.path == "/api/resource/Raven Channel/parent" { return stubResponse(request, 403, "{}") }
            if request.url!.path.contains("Raven Message") { return stubResponse(request, 200, #"{"data":{"name":"root","channel_id":"parent"}}"#) }
            return stubResponse(request, 200, #"{"data":{"name":"thread","channel_name":"root","is_thread":1,"is_archived":1}}"#)
        }
        await #expect(throws: RavenError.self) { try await client(denied).channelReadContext("thread") }
    }
    @Test func writableCanonicalChannelsRequireRecognizedFlags() async throws {
        let session = StubURLProtocol.install { request in stubResponse(request, 200, #"{"data":{"name":"channel","is_thread":false,"is_archived":false}}"#) }
        #expect(try await client(session).channelWriteContext("channel").isArchived == false)
        let malformed = StubURLProtocol.install { request in stubResponse(request, 200, #"{"data":{"name":"channel"}}"#) }
        await #expect(throws: RavenError.invalidResponse) { try await client(malformed).channelWriteContext("channel") }
    }
    @Test func cyclicThreadParentsCannotAuthorizeASend() async throws {
        let session = StubURLProtocol.install { request in
            if request.url!.path.contains("Raven Message") { return stubResponse(request, 200, #"{"data":{"name":"root","channel_id":"thread"}}"#) }
            return stubResponse(request, 200, #"{"data":{"name":"thread","channel_name":"root","is_thread":true,"is_archived":false}}"#)
        }
        await #expect(throws: RavenError.invalidResponse) { try await client(session).channelWriteContext("thread") }
    }
}
