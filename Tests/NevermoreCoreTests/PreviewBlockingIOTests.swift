import XCTest
@testable import NevermoreCore

final class PreviewBlockingIOTests: XCTestCase {
    func testBlockingOperationRunsOutsideASwiftTask() async {
        // This is true on a dispatch worker, false in Task.detached. No
        // sleeps, network or deliberate executor starvation are needed.
        let outsideTask = await PreviewBlockingIO.run {
            withUnsafeCurrentTask { $0 == nil }
        }
        XCTAssertTrue(outsideTask, "Synchronous DNS/curl must not occupy a cooperative executor thread")
    }

    func testBlockingOperationReturnsItsValue() async {
        let result = await PreviewBlockingIO.run { 42 }
        XCTAssertEqual(result, 42)
    }
}
