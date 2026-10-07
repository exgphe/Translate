import Foundation

public struct ServerSentEvent: Hashable, Sendable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental text/event-stream parser. Feed one line at a time; an event is returned when a
/// blank line terminates it. Works with `URLSession.AsyncBytes.lines` and with tests.
public struct SSELineParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastID: String?

    public init() {}

    public mutating func feed(line rawLine: String) -> ServerSentEvent? {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }

        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil // comment / keep-alive
        }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastID = String(value)
        default: break // "retry" and unknown fields are ignored
        }
        return nil
    }

    /// Emits any buffered event when the stream ends without a trailing blank line.
    public mutating func flush() -> ServerSentEvent? {
        dispatch()
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        return ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastID)
    }
}
