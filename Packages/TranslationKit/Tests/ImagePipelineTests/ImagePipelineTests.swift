import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ImagePipeline

struct TextLayoutTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.5, h: CGFloat = 0.05) -> RecognizedLine {
        RecognizedLine(text: text, confidence: 1, boundingBox: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func ordersTopToBottomThenLeftToRight() {
        let lines = [line("c", x: 0.1, y: 0.2), line("b", x: 0.6, y: 0.8, w: 0.3), line("a", x: 0.1, y: 0.8, w: 0.3)]
        #expect(TextLayout.readingOrder(lines).map(\.text) == ["a", "b", "c"])
    }

    @Test func insertsParagraphBreaksForLargeGaps() {
        let lines = [line("one", x: 0, y: 0.90), line("two", x: 0, y: 0.84), line("three", x: 0, y: 0.60)]
        #expect(TextLayout.assemble(TextLayout.readingOrder(lines)) == "one\ntwo\n\nthree")
    }

    @Test func joinsSameRowWithSpaces() {
        let lines = [line("left", x: 0.0, y: 0.5, w: 0.3), line("right", x: 0.5, y: 0.5, w: 0.3)]
        #expect(TextLayout.assemble(TextLayout.readingOrder(lines)) == "left right")
    }
}

struct VisionRecognitionTests {
    /// Draws text into a bitmap so the test does not depend on fixture files.
    private func render(_ text: String, size: CGSize = CGSize(width: 900, height: 240)) throws -> ImportedImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let lineRef = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: size.height / 2 - 16)
        CTLineDraw(lineRef, context)
        return ImportedImage(cgImage: try #require(context.makeImage()))
    }

    @Test func recognizesRenderedEnglishText() async throws {
        let image = try render("Please sign the attached form")
        let document = try await VisionTextRecognizer().recognize(image, languages: [])
        #expect(!document.isEmpty)
        #expect(document.text.lowercased().contains("sign"))
        #expect(document.text.lowercased().contains("form"))
        #expect(document.imageSize == CGSize(width: 900, height: 240))
    }

    @Test func blankImageYieldsNoText() async throws {
        let image = try render(" ")
        let document = try await VisionTextRecognizer().recognize(image, languages: [])
        #expect(document.isEmpty)
    }

    @Test func rejectsGarbageData() {
        #expect(throws: ImagePipelineError.self) { try ImageLoader.load(Data([0, 1, 2, 3])) }
    }
}
