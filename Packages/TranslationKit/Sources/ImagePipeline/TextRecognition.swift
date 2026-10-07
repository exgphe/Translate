import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct RecognizedLine: Hashable, Sendable {
    public var text: String
    public var confidence: Float
    /// Normalized rect in Vision coordinates (origin bottom-left, 0...1).
    public var boundingBox: CGRect

    public init(text: String, confidence: Float, boundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct RecognizedDocument: Hashable, Sendable {
    public var lines: [RecognizedLine]
    /// Lines joined in reading order with paragraph breaks where the layout suggests them.
    public var text: String
    public var imageSize: CGSize

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var averageConfidence: Float {
        guard !lines.isEmpty else { return 0 }
        return lines.map(\.confidence).reduce(0, +) / Float(lines.count)
    }

    public init(lines: [RecognizedLine], text: String, imageSize: CGSize) {
        self.lines = lines
        self.text = text
        self.imageSize = imageSize
    }
}

public enum ImagePipelineError: Error, LocalizedError, Sendable {
    case unreadableImage
    case noTextFound

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: "The image could not be read."
        case .noTextFound: "No text was found in the image."
        }
    }
}

/// A decoded image together with its EXIF orientation, ready for OCR.
public struct ImportedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let orientation: CGImagePropertyOrientation

    public init(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) {
        self.cgImage = cgImage
        self.orientation = orientation
    }

    public var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }
}

public enum ImageLoader {
    /// Decodes PNG/JPEG/HEIC/TIFF data. Keeps the orientation so OCR sees upright text.
    public static func load(_ data: Data) throws -> ImportedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePipelineError.unreadableImage
        }
        var orientation = CGImagePropertyOrientation.up
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = properties[kCGImagePropertyOrientation] as? UInt32,
           let parsed = CGImagePropertyOrientation(rawValue: raw) {
            orientation = parsed
        }
        return ImportedImage(cgImage: image, orientation: orientation)
    }

    public static func load(contentsOf url: URL) throws -> ImportedImage {
        try load(Data(contentsOf: url))
    }
}

public protocol TextRecognizer: Sendable {
    func recognize(_ image: ImportedImage, languages: [Locale.Language]) async throws -> RecognizedDocument
}

/// On-device OCR with Vision. Nothing leaves the device.
public struct VisionTextRecognizer: TextRecognizer {
    public init() {}

    public func recognize(_ image: ImportedImage, languages: [Locale.Language] = []) async throws -> RecognizedDocument {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        let observations = try await request.perform(on: image.cgImage, orientation: image.orientation)
        let lines: [RecognizedLine] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, confidence: candidate.confidence, boundingBox: observation.boundingBox.cgRect)
        }
        let ordered = TextLayout.readingOrder(lines)
        return RecognizedDocument(lines: ordered, text: TextLayout.assemble(ordered), imageSize: image.pixelSize)
    }
}

/// Layout heuristics kept separate so they can be unit tested without Vision.
public enum TextLayout {
    /// Sorts top-to-bottom, then left-to-right for lines on the same row.
    public static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.sorted { a, b in
            let overlap = min(a.boundingBox.maxY, b.boundingBox.maxY) - max(a.boundingBox.minY, b.boundingBox.minY)
            let minHeight = min(a.boundingBox.height, b.boundingBox.height)
            if minHeight > 0, overlap / minHeight > 0.5 {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return a.boundingBox.midY > b.boundingBox.midY
        }
    }

    /// Joins lines; inserts a blank line when the vertical gap is clearly larger than a line.
    public static func assemble(_ lines: [RecognizedLine]) -> String {
        var output = ""
        var previous: RecognizedLine?
        for line in lines {
            if let previous {
                let gap = previous.boundingBox.minY - line.boundingBox.maxY
                let reference = max(previous.boundingBox.height, line.boundingBox.height, 0.001)
                let sameRow = abs(previous.boundingBox.midY - line.boundingBox.midY) < reference * 0.5
                if sameRow {
                    output += " "
                } else if gap > reference * 0.9 {
                    output += "\n\n"
                } else {
                    output += "\n"
                }
            }
            output += line.text
            previous = line
        }
        return output
    }
}
