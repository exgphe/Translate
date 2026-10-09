@preconcurrency import AVFAudio
import CoreMedia
import Foundation

/// A PCM buffer handed from the capture queue to the recognizer. The buffer is created for
/// this hop and never mutated afterwards, so passing it across tasks is safe.
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer

    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Copies the PCM data out of a capture sample buffer.
    public init?(copying sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              description.mediaType == .audio else { return nil }
        guard let format = AVAudioFormat(formatDescription: description) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        self.buffer = buffer
    }
}

/// Converts arbitrary PCM buffers to the format the speech analyzer wants (usually 16 kHz mono).
final class BufferConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { throw LiveCaptionsError.audioConversionFailed }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw LiveCaptionsError.audioConversionFailed
        }
        let feed = OneShotFeed(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feed.next(inputStatus)
        }
        if status == .error { throw error ?? LiveCaptionsError.audioConversionFailed }
        return output.frameLength > 0 ? output : nil
    }

    /// Supplies the input buffer exactly once per conversion call.
    private final class OneShotFeed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}

public enum LiveCaptionsError: Error, LocalizedError, Equatable {
    case speechRecognitionUnavailable
    case unsupportedSpokenLanguage(String)
    case noAudioFormat
    case audioConversionFailed
    case captureUnavailable
    case pickerCancelled
    case pickerFailed(String)
    case captureStopped(String)
    case translationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .speechRecognitionUnavailable: "Speech recognition is not available on this device."
        case .unsupportedSpokenLanguage(let language): "Speech recognition does not support \(language)."
        case .noAudioFormat: "Speech recognition could not agree on an audio format."
        case .audioConversionFailed: "The captured audio could not be converted for speech recognition."
        case .captureUnavailable: "Capturing other apps' audio is not available on this device."
        case .pickerCancelled: "No window or app was chosen."
        case .pickerFailed(let message): "The content picker failed: \(message)"
        case .captureStopped(let message): "Audio capture stopped: \(message)"
        case .translationFailed(let reason): "Apple Translation failed: \(reason)"
        }
    }
}
