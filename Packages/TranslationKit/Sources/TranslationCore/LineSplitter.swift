import Foundation

/// Splits a byte stream into lines while preserving empty lines. `AsyncBytes.lines` drops
/// blank lines, which breaks Server-Sent Events because a blank line terminates an event.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds one byte; returns a complete line (without its terminator) when one ends.
    public mutating func feed(_ byte: UInt8) -> String? {
        if byte == UInt8(ascii: "\n") {
            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }

    /// Returns the unterminated trailing line, if any.
    public mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
