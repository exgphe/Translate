import Foundation
import Testing
@testable import LiveCaptions

private enum SessionTestError: Error, Equatable {
    case recognitionFailed
    case conversionFailed
    case startFailed
}

private final class SessionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    var events: [String] {
        lock.withLock { recorded }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StreamingSessionTests {
    @Test func recognitionErrorStopsAnOngoingAudioStream() async {
        let probe = SessionProbe()
        let (audio, _) = AsyncStream.makeStream(of: Int.self)
        let (started, signal) = AsyncStream.makeStream(of: Void.self)

        await #expect(throws: SessionTestError.recognitionFailed) {
            try await runStreamingSession(
                start: {},
                input: {
                    defer { probe.record("input stopped") }
                    signal.yield(())
                    for await _ in audio {}
                },
                results: {
                    var iterator = started.makeAsyncIterator()
                    _ = await iterator.next()
                    throw SessionTestError.recognitionFailed
                },
                cancel: { probe.record("cleanup") }
            )
        }

        #expect(probe.events.contains("input stopped"))
        #expect(probe.events.contains("cleanup"))
    }

    @Test func conversionErrorStopsTheResultConsumer() async {
        let probe = SessionProbe()
        let (pendingResults, _) = AsyncStream.makeStream(of: Int.self)
        let (started, signal) = AsyncStream.makeStream(of: Void.self)

        await #expect(throws: SessionTestError.conversionFailed) {
            try await runStreamingSession(
                start: {},
                input: {
                    var iterator = started.makeAsyncIterator()
                    _ = await iterator.next()
                    throw SessionTestError.conversionFailed
                },
                results: {
                    defer { probe.record("results stopped") }
                    signal.yield(())
                    for await _ in pendingResults {}
                },
                cancel: { probe.record("cleanup") }
            )
        }

        #expect(probe.events.contains("results stopped"))
        #expect(probe.events.contains("cleanup"))
    }

    @Test func startupFailureCleansUpWithoutLaunchingConsumers() async {
        let probe = SessionProbe()

        await #expect(throws: SessionTestError.startFailed) {
            try await runStreamingSession(
                start: { throw SessionTestError.startFailed },
                input: { probe.record("input started") },
                results: { probe.record("results started") },
                cancel: { probe.record("cleanup") }
            )
        }

        #expect(probe.events == ["cleanup"])
    }

    @Test func inputCompletionDrainsBufferedFinalResults() async throws {
        let probe = SessionProbe()
        let (inputFinished, signal) = AsyncStream.makeStream(of: Void.self)

        try await runStreamingSession(
            start: {},
            input: {
                probe.record("input finished")
                signal.yield(())
            },
            results: {
                var iterator = inputFinished.makeAsyncIterator()
                _ = await iterator.next()
                // An input operation can finish before the final phrases are consumed.
                await Task.yield()
                try Task.checkCancellation()
                probe.record("final result")
            },
            cancel: { probe.record("cleanup") }
        )

        #expect(probe.events == ["input finished", "final result", "cleanup"])
    }

    @Test func resultCompletionStopsAudioEvenWithoutAnError() async throws {
        let probe = SessionProbe()
        let (audio, _) = AsyncStream.makeStream(of: Int.self)
        let (started, signal) = AsyncStream.makeStream(of: Void.self)

        try await runStreamingSession(
            start: {},
            input: {
                defer { probe.record("input stopped") }
                signal.yield(())
                for await _ in audio {}
            },
            results: {
                var iterator = started.makeAsyncIterator()
                _ = await iterator.next()
            },
            cancel: { probe.record("cleanup") }
        )

        #expect(probe.events.contains("input stopped"))
        #expect(probe.events.contains("cleanup"))
    }

    @Test func cancellingTheSessionJoinsBothConsumers() async {
        let probe = SessionProbe()
        let (audio, _) = AsyncStream.makeStream(of: Int.self)
        let (pendingResults, _) = AsyncStream.makeStream(of: Int.self)
        let (started, signal) = AsyncStream.makeStream(of: Void.self)

        let session = Task {
            try await runStreamingSession(
                start: {},
                input: {
                    defer { probe.record("input stopped") }
                    signal.yield(())
                    for await _ in audio {}
                },
                results: {
                    defer { probe.record("results stopped") }
                    signal.yield(())
                    for await _ in pendingResults {}
                },
                cancel: { probe.record("cleanup") }
            )
        }

        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        session.cancel()
        await #expect(throws: CancellationError.self) { try await session.value }
        #expect(probe.events.contains("input stopped"))
        #expect(probe.events.contains("results stopped"))
        #expect(probe.events.contains("cleanup"))
    }
}
