import XCTest
@testable import WorkspaceCore

final class AsyncPollingTests: XCTestCase {
    @MainActor func testWaitsForObservedStateAfterSeveralUnsuccessfulPolls() async throws {
        var polls = 0
        let reached = try await AsyncPolling.until(timeout: 1, interval: 0.001) {
            polls += 1
            return polls == 6
        }
        XCTAssertTrue(reached)
        XCTAssertEqual(polls, 6)
    }
    @MainActor func testDoesNotReportSuccessWhenTransitionNeverCompletes() async throws {
        let reached = try await AsyncPolling.until(timeout: 0.01, interval: 0.001) { false }
        XCTAssertFalse(reached)
    }
    @MainActor func testAlreadyActiveSpaceNeedsNoDelay() async throws {
        var polls = 0
        let reached = try await AsyncPolling.until(timeout: 0, interval: 0.001) { polls += 1; return true }
        XCTAssertTrue(reached)
        XCTAssertEqual(polls, 1)
    }
    @MainActor func testCancellationStopsWaiting() async throws {
        let task = Task { try await AsyncPolling.until(timeout: 60) { false } }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation was ignored") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    @MainActor func testInventoryFailureIsPropagated() async throws {
        enum Failure: Error { case displayDisconnected }
        do {
            _ = try await AsyncPolling.until(timeout: 1) { throw Failure.displayDisconnected }
            XCTFail("The inventory failure was ignored")
        } catch Failure.displayDisconnected {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
