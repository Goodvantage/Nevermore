import Foundation

/// AuthenticationServices may call its completion on an XPC background queue.
/// Return an explicitly Sendable, nonisolated callback so Swift never infers
/// the login controller's main-actor isolation for the framework entry point.
enum BrowserAuthenticationCallback {
    nonisolated static func makeHandler(
        _ receive: @escaping @MainActor @Sendable (URL?, (any Error)?) async -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { @Sendable callback, error in
            Task { @MainActor in await receive(callback, error) }
        }
    }
}
