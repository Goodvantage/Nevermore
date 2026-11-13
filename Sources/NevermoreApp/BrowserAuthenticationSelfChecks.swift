import Foundation

@MainActor private final class AuthenticationCallbackProbe {
    var deliveries = 0
    var callback: URL?
    var errorCode: Int?
    func receive(_ callback: URL?, _ error: (any Error)?) {
        MainActor.preconditionIsolated()
        self.callback = callback; errorCode = (error as NSError?)?.code
        deliveries += 1
    }
}

@MainActor enum BrowserAuthenticationSelfChecks {
    static func run() async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let success = AuthenticationCallbackProbe()
        let callbackURL = URL(string: "ch.goodvantage.Nevermore://oauth?state=local-fixture")!
        let completion = BrowserAuthenticationCallback.makeHandler { callback, error in success.receive(callback, error) }
        let cameFromBackground: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let background = !Thread.isMainThread
                completion(callbackURL, nil)
                continuation.resume(returning: background)
            }
        }
        for _ in 0..<100 { if success.deliveries > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        results.append(("browser authentication callbacks safely reach MainActor from a background executor", cameFromBackground && success.deliveries == 1 && success.callback == callbackURL && success.errorCode == nil))

        let cancellation = AuthenticationCallbackProbe()
        let cancel = BrowserAuthenticationCallback.makeHandler { callback, error in cancellation.receive(callback, error) }
        await Task.detached { cancel(nil, NSError(domain: "NevermoreAuthenticationFixture", code: 1)) }.value
        for _ in 0..<100 { if cancellation.deliveries > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        results.append(("browser authentication cancellation retains its error across the actor handoff", cancellation.deliveries == 1 && cancellation.callback == nil && cancellation.errorCode == 1))

        let missing = AuthenticationCallbackProbe()
        let empty = BrowserAuthenticationCallback.makeHandler { callback, error in missing.receive(callback, error) }
        await Task.detached { empty(nil, nil) }.value
        for _ in 0..<100 { if missing.deliveries > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        results.append(("browser authentication forwards an empty result without inventing a callback", missing.deliveries == 1 && missing.callback == nil && missing.errorCode == nil))
        return results
    }
}
