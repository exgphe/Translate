import Foundation
import TranslationCore

/// Shared helpers for cloud adapters: status mapping, error-body reading, SSE iteration.
enum HTTPSupport {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Reads the remaining bytes of a failed response and maps it to a `TranslationError`.
    static func error(for response: HTTPURLResponse, bytes: URLSession.AsyncBytes, providerName: String) async -> TranslationError {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64_000 { break }
            }
        } catch {
            // Ignore; we already know the status.
        }
        let message = extractMessage(from: body) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        switch response.statusCode {
        case 401, 403: return .authenticationFailed
        case 402: return .quotaExceeded
        case 429:
            let retry = response.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
            return .rateLimited(retryAfterSeconds: retry)
        default:
            if message.localizedCaseInsensitiveContains("credit") || message.localizedCaseInsensitiveContains("quota") {
                return .quotaExceeded
            }
            return .providerError(status: response.statusCode, message: message)
        }
    }

    static func extractMessage(from body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String { return message }
                if let type = error["type"] as? String { return type }
            }
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
        }
        return String(data: body.prefix(500), encoding: .utf8)
    }

    static func mapTransportError(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return TranslationError.network(urlError.localizedDescription)
        }
        return error
    }

    /// Guesses whether a base URL points at a service on this machine or the local network.
    static func processingLocation(for url: URL) -> ProcessingLocation {
        guard let host = url.host()?.lowercased() else { return .cloud }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" || host.hasSuffix(".local") {
            return .localServer
        }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return .localServer
        }
        return .cloud
    }
}
