import AppKit
import MyPetCore
import MyPetRender

/// CastProp 的 AppKit 表现适配器。
///
/// Core 的 CastVisualProjection 只提供已确认实体的安全框；这个类型只把
/// prop 投影成一个独立的浮层，不创建世界状态，也不参与 slot/剧情决策。
final class CastPropOverlay {
    let propID: String
    private let visualID: String
    private let emoji: String
    private let panel: OverlayPanel
    private let imageView: NSImageView
    private var handoffPresentation: HandoffPresentation?

    private struct HandoffPresentation {
        let from: LayoutRect
        let to: LayoutRect
        let startedAt: Double
        let duration: Double
    }

    init(prop: CastProp) {
        propID = prop.id
        visualID = prop.visualPackID ?? prop.id
        emoji = PropCatalog.def(prop.visualPackID ?? prop.id)?.emoji ?? "◼︎"
        imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        panel = OverlayPanel(
            contentView: imageView,
            initialFrame: NSRect(x: 0, y: 0, width: 64, height: 64))
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    func update(frame: LayoutRect, now: Double) {
        let presentedFrame: LayoutRect
        if let handoff = handoffPresentation {
            let progress = min(1, max(0, (now - handoff.startedAt) / handoff.duration))
            let eased = progress * progress * (3 - 2 * progress)
            let arc = min(48, max(8, abs(handoff.to.x - handoff.from.x) * 0.18)) *
                sin(.pi * eased)
            presentedFrame = LayoutRect(
                x: handoff.from.x + (handoff.to.x - handoff.from.x) * eased,
                y: handoff.from.y + (handoff.to.y - handoff.from.y) * eased - arc,
                width: handoff.from.width + (handoff.to.width - handoff.from.width) * eased,
                height: handoff.from.height + (handoff.to.height - handoff.from.height) * eased)
            if progress >= 1 { handoffPresentation = nil }
        } else {
            presentedFrame = frame
        }

        let size = CGFloat(max(24, min(presentedFrame.width, presentedFrame.height)))
        let rect = Screens.appKitRect(
            flippedTop: CGFloat(presentedFrame.y),
            x: CGFloat(presentedFrame.x),
            width: size,
            height: size)
        panel.setFrame(rect, display: false)
        let urls = PropSprites.frameURLs(for: visualID, packURL: nil)
        let image: CGImage?
        if urls.count > 1 {
            let index = Int(now * 5) % urls.count
            image = PropSprites.cgImage(urls[index])
        } else if let url = urls.first {
            image = PropSprites.cgImage(url)
        } else {
            image = PropSprites.emojiImage(emoji, size: size)
        }
        imageView.image = image.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
    }

    /// Starts a visual-only transfer. Core has already emitted the boundary
    /// event; the next steady projection remains authoritative after the cue.
    func beginHandoff(
        from frame: LayoutRect,
        toActorFrame: LayoutRect,
        now: Double,
        durationTicks: Int64
    ) {
        let propSize = min(frame.width, frame.height)
        let destination = CastVisualProjection.attachedPropFrame(
            actorFrame: toActorFrame,
            propSize: propSize)
        handoffPresentation = HandoffPresentation(
            from: frame,
            to: destination,
            startedAt: now,
            duration: max(0.025, Double(max(1, durationTicks)) * 0.025))
    }

    func close() {
        handoffPresentation = nil
        panel.orderOut(nil)
    }
}
