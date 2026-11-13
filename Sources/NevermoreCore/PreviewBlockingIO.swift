import Foundation

/// DNS resolution and the curl request are synchronous. Task.detached still
/// runs on Swift's cooperative executor and can starve unrelated async work.
enum PreviewBlockingIO {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: operation())
            }
        }
    }
}
