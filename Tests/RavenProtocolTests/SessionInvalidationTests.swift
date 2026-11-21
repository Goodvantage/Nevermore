import Foundation
import Testing
@testable import RavenProtocol

/// Records a session's invalidation through the delegate callback, so a test
/// can observe the teardown itself rather than a flag the client sets.
private final class InvalidationRecorder: NSObject, URLSessionDelegate {
    private let invalidated = DispatchSemaphore(value: 0)
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        invalidated.signal()
    }
    func wait() -> Bool { invalidated.wait(timeout: .now() + 5) == .success }
}

@Suite(.serialized)
struct SessionInvalidationSuite {

    /// A client must tear down the session it created. Re-login and account
    /// removal both drop the client, so an owned session has to be released
    /// there or it leaks until the process ends.
    @Test func invalidateReleasesAnOwnedSession() async {
        let recorder = InvalidationRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        let client = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture",
                                 accountID: UUID(), session: session, ownsSession: true)
        #expect(await client.didInvalidateSession == false)
        await client.invalidate()
        #expect(await client.didInvalidateSession)
        #expect(recorder.wait())
    }

    /// A session injected by a contract test belongs to the test; one client
    /// invalidating it would break a sibling that shares the same session.
    @Test func invalidateLeavesAnInjectedSessionAlone() async {
        let session = URLSession(configuration: .ephemeral)
        let client = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture",
                                 accountID: UUID(), session: session)
        await client.invalidate()
        #expect(await client.didInvalidateSession == false)
        session.finishTasksAndInvalidate()
    }

    @Test func revokeReleasesAnOwnedSession() async {
        let recorder = InvalidationRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        let client = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture",
                                 accountID: UUID(), session: session, ownsSession: true)
        await client.revoke()
        #expect(await client.didInvalidateSession)
        #expect(recorder.wait())
    }

    @Test func revokeLeavesAnInjectedSessionAlone() async {
        let session = URLSession(configuration: .ephemeral)
        let client = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture",
                                 accountID: UUID(), session: session)
        await client.revoke()
        #expect(await client.didInvalidateSession == false)
        session.finishTasksAndInvalidate()
    }

    /// A client that created its own session and is then dropped must still
    /// release it: no caller ran invalidate() or revoke().
    @Test func deinitReleasesAnOwnedSession() {
        let recorder = InvalidationRecorder()
        let session = URLSession(configuration: .ephemeral, delegate: recorder, delegateQueue: nil)
        var client: RavenClient? = RavenClient(origin: URL(string: "https://site.test")!, tokens: nil, clientID: "fixture",
                                               accountID: UUID(), session: session, ownsSession: true)
        client = nil
        #expect(recorder.wait())
        session.finishTasksAndInvalidate()
    }
}
