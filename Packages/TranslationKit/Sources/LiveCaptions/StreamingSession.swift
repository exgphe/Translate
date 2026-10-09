import Foundation

private enum StreamingSessionCompletion: Sendable {
    case input
    case results
}

/// Owns both sides of an ongoing analysis. Input completion permits pending results to drain;
/// result completion or an error stops input immediately, even when capture is still running.
/// `cancel` must be safe to repeat, and must unblock any framework operations awaiting input.
func runStreamingSession(
    start: @escaping @Sendable () async throws -> Void,
    input: @escaping @Sendable () async throws -> Void,
    results: @escaping @Sendable () async throws -> Void,
    cancel: @escaping @Sendable () async -> Void
) async throws {
    try await withTaskCancellationHandler {
        do {
            try Task.checkCancellation()
            try await start()
            try Task.checkCancellation()
        } catch {
            await cancel()
            throw error
        }

        try await withThrowingTaskGroup(of: StreamingSessionCompletion.self) { group in
            group.addTask {
                try await input()
                return .input
            }
            group.addTask {
                try await results()
                return .results
            }

            do {
                if try await group.next() == .results {
                    group.cancelAll()
                } else {
                    // The input operation finalizes the analyzer before returning. Its result
                    // stream may still contain buffered final phrases; keep consuming them.
                    try await group.waitForAll()
                }
                await cancel()
                try Task.checkCancellation()
            } catch {
                group.cancelAll()
                await cancel()
                throw error
            }
        }
    } onCancel: {
        // Cancellation handlers are synchronous. End the analyzer asynchronously so a child
        // suspended inside a framework call can return and the task group can finish joining.
        Task { await cancel() }
    }
}
