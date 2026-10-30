import Foundation

public enum AsyncPolling {
    /// Wait for the observable state, rather than treating the dispatch of an asynchronous action as completion.
    @MainActor public static func until(timeout: TimeInterval, interval: TimeInterval = 0.1,
                                       condition: () throws -> Bool) async throws -> Bool {
        precondition(timeout >= 0 && interval > 0)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while true {
            try Task.checkCancellation()
            if try condition() { return true }
            if clock.now >= deadline { return false }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
