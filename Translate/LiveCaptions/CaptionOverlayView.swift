#if os(macOS) || os(visionOS)
import CaptionFeed
import SwiftUI

/// The captions themselves. On macOS this fills a transparent click-through panel at the
/// bottom of the screen; on visionOS it is a window the person places under the video.
struct CaptionOverlayView: View {
    @Environment(LiveCaptionsController.self) private var controller

    var body: some View {
        #if os(visionOS)
        CaptionHistoryView(items: controller.historyItems, textSize: controller.textSize,
                           status: controller.phase == .running ? "Listening…" : controller.statusText)
            .glassBackgroundEffect()
        #else
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
        #endif
    }

    @ViewBuilder
    private var placeholder: some View {
        if controller.isAdjustingPosition {
            CaptionBubble(
                item: .init(id: "sample", primary: "Drag to place the captions", secondary: "Turn off “Adjust caption position” when done", isProvisional: false),
                textSize: controller.textSize
            )
        }
    }
}

#if os(visionOS)
private struct CaptionHistoryView: View {
    let items: [CaptionFeedSnapshot.DisplayLine]
    let textSize: Double
    let status: String
    @State private var followsLatest = true

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if items.isEmpty {
                        Text(status).font(.title3).foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        CaptionBubble(item: item, textSize: textSize)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 1).id("caption-bottom")
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followsLatest = false }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                if atBottom { followsLatest = true }
            }
            .onChange(of: items) { _, _ in
                if items.isEmpty { followsLatest = true }
                guard followsLatest else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    reader.scrollTo("caption-bottom", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation { reader.scrollTo("caption-bottom", anchor: .bottom) }
                    } label: {
                        Label("Latest captions", systemImage: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .padding(16)
                }
            }
        }
    }
}

#Preview("Scrollable captions") {
    CaptionHistoryView(
        items: (1...12).map { index in
            .init(id: "line-\(index)", primary: "第 \(index) 句：翻译完成后会保留在这里，可以向上滚动回看。",
                  secondary: nil, isProvisional: false)
        },
        textSize: 28, status: "Listening…"
    )
    .frame(width: 1100, height: 260)
    .glassBackgroundEffect()
}
#endif

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
        #if os(macOS)
        .lineLimit(3)
        #else
        .fixedSize(horizontal: false, vertical: true)
        #endif
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
