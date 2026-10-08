#if os(macOS) || os(visionOS)
import SwiftUI

/// The captions themselves. On macOS this fills a transparent click-through panel at the
/// bottom of the screen; on visionOS it is a window the person places under the video.
struct CaptionOverlayView: View {
    @Environment(LiveCaptionsController.self) private var controller

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let items = controller.displayItems(now: context.date)
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                if items.isEmpty {
                    placeholder
                } else {
                    ForEach(items) { item in
                        CaptionBubble(item: item, textSize: controller.textSize)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(16)
            .animation(.easeOut(duration: 0.15), value: items)
        }
        .overlay {
            if controller.isAdjustingPosition {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        #if os(visionOS)
        .glassBackgroundEffect()
        #endif
    }

    @ViewBuilder
    private var placeholder: some View {
        if controller.isAdjustingPosition {
            CaptionBubble(
                item: .init(id: "sample", primary: "Drag to place the captions", secondary: "Turn off “Adjust caption position” when done", isProvisional: false),
                textSize: controller.textSize
            )
        } else {
            #if os(visionOS)
            Text(controller.phase == .running ? "Listening…" : controller.statusText)
                .font(.title3)
                .foregroundStyle(.secondary)
            #endif
        }
    }
}

struct CaptionBubble: View {
    let item: LiveCaptionsController.DisplayItem
    let textSize: Double

    var body: some View {
        VStack(spacing: 4) {
            Text(item.primary)
                .font(.system(size: textSize, weight: .semibold))
                .opacity(item.isProvisional ? 0.8 : 1)
            if let secondary = item.secondary {
                Text(secondary)
                    .font(.system(size: max(textSize * 0.6, 12)))
                    .opacity(0.75)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        #if os(macOS)
        .foregroundStyle(.white)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        #endif
        .accessibilityElement(children: .combine)
    }
}
#endif
