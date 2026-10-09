#if os(macOS) || os(visionOS) || os(iOS)
import CoreMedia
import Foundation

public struct AudioCaptureProgress: Sendable {
    public var lastAudioAt: Date?
    public var bufferCount: Int

    public init(lastAudioAt: Date? = nil, bufferCount: Int = 0) {
        self.lastAudioAt = lastAudioAt
        self.bufferCount = bufferCount
    }
}
#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit

/// What the person chose in the system picker. Opaque so callers never handle capture filters.
public struct CaptureSource: @unchecked Sendable {
    let filter: SCContentFilter
}

/// Captures the audio of the window or app the person picked, excluding this app's own sound.
/// Nothing is recorded to disk; buffers go straight to speech recognition.
public final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LiveCaptions.SystemAudioCapture")
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stopHandler: (@Sendable (LiveCaptionsError?) -> Void)?
    private var audioProgress = AudioCaptureProgress()

    public var progress: AudioCaptureProgress { lock.withLock { audioProgress } }

    override public init() {}

    /// Starts capturing. `onStop` is called if the system ends the capture (for example when
    /// the person stops sharing from Control Center or the captured window closes).
    public func start(
        source: CaptureSource,
        onStop: @escaping @Sendable (LiveCaptionsError?) -> Void
    ) async throws -> AsyncStream<AudioChunk> {
        let filter = source.filter
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        // Speech recognition works at 16 kHz mono, so ask for that and skip a conversion step.
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        #if os(macOS) || os(iOS)
        // Video is required by the API but unused: keep it tiny.
        configuration.width = 2
        configuration.height = 2
        #endif
        #if os(macOS)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        #endif

        let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(256))
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // A screen output keeps ScreenCaptureKit from logging every dropped video frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)

        lock.withLock {
            self.stream = stream
            self.continuation = continuation
            self.stopHandler = onStop
            self.audioProgress = AudioCaptureProgress()
        }
        do {
            try await stream.startCapture()
        } catch {
            finish(with: nil)
            throw error
        }
        return audio
    }

    public func stop() async {
        let stream = lock.withLock { self.stream }
        try? await stream?.stopCapture()
        finish(with: nil)
    }

    private func finish(with error: LiveCaptionsError?) {
        let (continuation, handler) = lock.withLock { () -> (AsyncStream<AudioChunk>.Continuation?, (@Sendable (LiveCaptionsError?) -> Void)?) in
            defer {
                self.stream = nil
                self.continuation = nil
                self.stopHandler = nil
            }
            return (self.continuation, self.stopHandler)
        }
        continuation?.finish()
        if let error { handler?(error) }
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let chunk = AudioChunk(copying: sampleBuffer) else { return }
        let continuation = lock.withLock {
            audioProgress.lastAudioAt = .now
            audioProgress.bufferCount += 1
            return self.continuation
        }
        _ = continuation?.yield(chunk)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finish(with: .captureStopped(error.localizedDescription))
    }
}

/// Wraps the system content picker so the app never enumerates windows itself; the person
/// chooses what may be captured.
@MainActor
public final class CaptureContentPicker: NSObject {
    private var continuation: CheckedContinuation<SCContentFilter, any Error>?

    override public init() {}

    public static var isAvailable: Bool {
        SCContentSharingPicker.shared.isAvailable
    }

    public func pick() async throws -> CaptureSource {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        #if os(macOS)
        configuration.allowedPickerModes = [.singleWindow, .singleApplication]
        if let bundleID = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [bundleID] }
        #endif
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        defer { picker.remove(self) }

        continuation?.resume(throwing: LiveCaptionsError.pickerCancelled)
        let filter = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present()
        }
        return CaptureSource(filter: filter)
    }

    /// Call when capture ends so the system stops offering this app in its sharing UI.
    public func deactivate() {
        SCContentSharingPicker.shared.isActive = false
    }

    private func resume(with result: sending Result<SCContentFilter, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension CaptureContentPicker: SCContentSharingPickerObserver {
    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.resume(with: .failure(LiveCaptionsError.pickerCancelled)) }
    }

    nonisolated public func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.resume(with: .success(filter)) }
    }

    nonisolated public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.resume(with: .failure(LiveCaptionsError.pickerFailed(message))) }
    }
}
#else
// Simulators ship without ScreenCaptureKit. Same API, never available, so app code compiles
// unchanged and reports that capture is unavailable.

public struct CaptureSource: Sendable {}

public final class SystemAudioCapture: Sendable {
    public init() {}
    public var progress: AudioCaptureProgress { AudioCaptureProgress() }

    public func start(
        source: CaptureSource,
        onStop: @escaping @Sendable (LiveCaptionsError?) -> Void
    ) async throws -> AsyncStream<AudioChunk> {
        throw LiveCaptionsError.captureUnavailable
    }

    public func stop() async {}
}

@MainActor
public final class CaptureContentPicker {
    public init() {}
    public static var isAvailable: Bool { false }
    public func pick() async throws -> CaptureSource { throw LiveCaptionsError.captureUnavailable }
    public func deactivate() {}
}
#endif
#endif
