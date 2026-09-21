import AppKit
import MyPetCore
import MyPetRender

/// Deterministic presentation fallback for a logical mech whose dedicated
/// sprite pack is not installed yet. It is deliberately a geometric overlay,
/// not an asset-completion claim: the Core projection still exposes the
/// missing `visualPackID` and the asset audit remains authoritative.
final class CastMechOverlay {
    let mechID: String
    private let panel: OverlayPanel
    private let view: CastMechFallbackView

    init(member: CastMember) {
        mechID = member.id
        view = CastMechFallbackView(title: member.displayName)
        panel = OverlayPanel(
            contentView: view,
            initialFrame: NSRect(x: 0, y: 0, width: 96, height: 120))
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.floatingWindow)))
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
    }

    func update(frame: LayoutRect, pilotName: String?) {
        let rect = Screens.appKitRect(
            flippedTop: CGFloat(frame.y),
            x: CGFloat(frame.x),
            width: CGFloat(frame.width),
            height: CGFloat(frame.height))
        panel.setFrame(rect, display: false)
        view.pilotName = pilotName
        view.needsDisplay = true
    }

    func close() {
        panel.orderOut(nil)
    }
}

private final class CastMechFallbackView: NSView {
    private let title: String
    var pilotName: String?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let body = bounds.insetBy(dx: 3, dy: 3)
        var stableHash: UInt64 = 1469598103934665603
        for byte in title.utf8 {
            stableHash ^= UInt64(byte)
            stableHash &*= 1099511628211
        }
        let hue = CGFloat(stableHash % 360) / 360
        let fill = NSColor(calibratedHue: hue, saturation: 0.56, brightness: 0.72, alpha: 0.86)
        let outline = NSColor(calibratedHue: hue, saturation: 0.42, brightness: 1.0, alpha: 0.95)

        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
        fill.setFill()
        bodyPath.fill()
        outline.setStroke()
        bodyPath.lineWidth = 2
        bodyPath.stroke()

        let cockpit = NSRect(
            x: body.midX - body.width * 0.20,
            y: body.height * 0.22,
            width: body.width * 0.40,
            height: body.height * 0.25)
        NSColor.white.withAlphaComponent(0.82).setFill()
        NSBezierPath(ovalIn: cockpit).fill()
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: cockpit.insetBy(dx: 3, dy: 3)).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(9, body.height * 0.11), weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let titleRect = NSRect(
            x: body.minX + 5,
            y: body.maxY - max(18, body.height * 0.18),
            width: body.width - 10,
            height: max(14, body.height * 0.16))
        (title as NSString).draw(in: titleRect, withAttributes: titleAttributes)

        if let pilotName {
            let pilotAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(8, body.height * 0.085)),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            ]
            let pilotRect = NSRect(
                x: body.minX + 5,
                y: body.minY + 5,
                width: body.width - 10,
                height: max(12, body.height * 0.13))
            ("驾驶员：\(pilotName)" as NSString).draw(in: pilotRect, withAttributes: pilotAttributes)
        }
    }
}
