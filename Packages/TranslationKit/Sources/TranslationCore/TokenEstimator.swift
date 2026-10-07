import Foundation

/// Rough, conservative token estimate used only to refuse obviously oversized prompts
/// before sending them. Real counts come from the provider's usage report.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                cjk += 1
            default:
                other += 1
            }
        }
        // CJK characters are roughly one token each; Latin text averages ~4 characters per token.
        return cjk + Int((Double(other) / 3.5).rounded(.up))
    }
}
