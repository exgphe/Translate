import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

enum Pasteboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func readImageData() -> Data? {
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return data }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first {
            return try? Data(contentsOf: url)
        }
        return nil
    }
}
#else
import UIKit

enum Pasteboard {
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }

    static func readString() -> String? {
        UIPasteboard.general.string
    }

    static func readImageData() -> Data? {
        UIPasteboard.general.image?.pngData()
    }
}
#endif

/// Accepts dropped image files and in-memory images alike.
struct DroppedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { DroppedImage(data: $0) }
        FileRepresentation(importedContentType: .image) { received in
            DroppedImage(data: try Data(contentsOf: received.file))
        }
    }
}

extension Image.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Cross-platform view helpers

extension View {
    /// Text fields for URLs, model IDs and keys: no autocorrect, no auto-capitalization.
    @ViewBuilder
    func technicalTextInput() -> some View {
        #if os(iOS) || os(visionOS)
        self.autocorrectionDisabled().textInputAutocapitalization(.never)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Fixed popover width on macOS; on iOS the popover adapts to a sheet, so no fixed size.
    @ViewBuilder
    func popoverSize(width: CGFloat) -> some View {
        #if os(macOS)
        self.frame(width: width)
        #else
        self.presentationDetents([.medium, .large])
        #endif
    }

    /// Borderless menu on macOS; the system default elsewhere.
    @ViewBuilder
    func compactMenuStyle() -> some View {
        #if os(macOS)
        self.menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}
