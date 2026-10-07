import Foundation
import CoreText
import CoreGraphics

// Usage: glyph <fontName> <character> <size>  -> prints SVG path data (y-down, origin at glyph origin) and metrics
let args = CommandLine.arguments
let fontName = args[1], ch = args[2], size = CGFloat(Double(args[3])!)
let font = CTFontCreateWithName(fontName as CFString, size, nil)
let actual = CTFontCopyPostScriptName(font) as String
var chars = Array(ch.utf16)
var glyphs = [CGGlyph](repeating: 0, count: chars.count)
CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
guard let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { print("NOPATH"); exit(1) }
let box = path.boundingBoxOfPath
var d = ""
func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
path.applyWithBlock { el in
    let p = el.pointee.points
    switch el.pointee.type {
    case .moveToPoint: d += "M\(f(p[0].x)) \(f(-p[0].y))"
    case .addLineToPoint: d += "L\(f(p[0].x)) \(f(-p[0].y))"
    case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(-p[0].y)) \(f(p[1].x)) \(f(-p[1].y))"
    case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(-p[0].y)) \(f(p[1].x)) \(f(-p[1].y)) \(f(p[2].x)) \(f(-p[2].y))"
    case .closeSubpath: d += "Z"
    @unknown default: break
    }
}
let out: [String: Any] = ["font": actual, "d": d, "minX": box.minX, "maxX": box.maxX, "minY": -box.maxY, "maxY": -box.minY]
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
