import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

enum Pasteboard {
    /// Change count right after this app last wrote to the pasteboard, so auto-paste can
    /// ignore our own copies.
    private(set) static var ownChangeCount = -1

    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        ownChangeCount = pasteboard.changeCount
    }

    static var changeCount: Int { NSPasteboard.general.changeCount }

    /// Type checks only; they do not read the contents. A Finder file copy also carries the
    /// file name as a string and the file icon as TIFF, so file copies count as images only
    /// when the file itself is an image, and never as text.
    static var hasText: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.availableType(from: [.string]) != nil && pasteboard.availableType(from: [.fileURL]) == nil
    }

    static var hasImage: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.availableType(from: [.fileURL]) != nil { return imageFileURL() != nil }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private static func imageFileURL() -> URL? {
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        ) as? [URL]
        return urls?.first
    }

    static func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func readImageData() -> Data? {
        let pasteboard = NSPasteboard.general
        // A copied image file wins over the TIFF icon Finder puts next to it.
        if pasteboard.availableType(from: [.fileURL]) != nil {
            return imageFileURL().flatMap { try? Data(contentsOf: $0) }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) { return data }
        }
        return nil
    }
}
#else
import UIKit

enum Pasteboard {
    /// Change count right after this app last wrote to the pasteboard, so auto-paste can
    /// ignore our own copies.
    private(set) static var ownChangeCount = -1

    static func copy(_ string: String) {
        UIPasteboard.general.string = string
        ownChangeCount = UIPasteboard.general.changeCount
    }

    static var changeCount: Int { UIPasteboard.general.changeCount }

    /// These checks do not read the contents, so they never trigger the paste prompt.
    static var hasText: Bool { UIPasteboard.general.hasStrings }
    static var hasImage: Bool { UIPasteboard.general.hasImages }

    static func readString() -> String? {
        UIPasteboard.general.string
    }

    static func readImageData() -> Data? {
        UIPasteboard.general.image?.pngData()
    }
}
#endif

/// What a system Paste button hands over. Text is preferred when both are offered.
nonisolated enum PastedContent: Transferable {
    case text(String)
    case image(Data)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (text: String) in PastedContent.text(text) })
        DataRepresentation(importedContentType: .image) { PastedContent.image($0) }
    }
}

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
