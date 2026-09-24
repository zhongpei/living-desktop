import AppKit
import CoreGraphics
import MyPetCombatCPU
import MyPetPlatform

@MainActor
final class CombatPlatformEffects {
    private let puller = WindowPuller()
    private var overlays: [NSPanel] = []

    func execute(_ intent: GameplayPlatformIntent, in world: WindowWorld) {
        switch intent {
        case .pullWindow(let surfaceID):
            guard WindowPuller.isTrusted(),
                  let window = Self.window(surfaceID, in: world) else { return }
            let start = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            puller.begin(windowID: window.id, pid: window.pid)
            puller.update(
                cursor: CGPoint(x: start.x + 48, y: start.y + 12),
                cursorStart: start,
                mass: WindowPuller.windowMass(forApp: window.owner))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.puller.end()
            }
        case .damageWindowOverlay(let surfaceID):
            guard let window = Self.window(surfaceID, in: world) else { return }
            showDamageOverlay(over: window.bounds)
        case .inspectWindow, .perchWindow, .rest, .observe, .interactProp, .perform:
            break
        }
    }

    static func windowID(from surfaceID: String) -> CGWindowID? {
        let components = surfaceID.split(separator: ":")
        guard components.count >= 2, components[0] == "window",
              let value = UInt32(components[1]) else { return nil }
        return CGWindowID(value)
    }

    private static func window(_ surfaceID: String, in world: WindowWorld) -> WindowEntity? {
        windowID(from: surfaceID).flatMap(world.window)
    }

    private func showDamageOverlay(over flippedBounds: CGRect) {
        let frame = Screens.appKitRect(
            flippedTop: flippedBounds.minY,
            x: flippedBounds.minX,
            width: flippedBounds.width,
            height: flippedBounds.height)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = WindowCrackGeometryView(frame: CGRect(origin: .zero, size: frame.size))
        panel.orderFrontRegardless()
        overlays.append(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak panel] in
            panel?.orderOut(nil)
            if let panel { self?.overlays.removeAll { $0 === panel } }
        }
    }
}

private final class WindowCrackGeometryView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        NSColor.white.withAlphaComponent(0.72).setStroke()
        for index in 0..<10 {
            let angle = Double(index) * .pi * 2 / 10
            let radius = min(bounds.width, bounds.height) * (index.isMultiple(of: 2) ? 0.22 : 0.34)
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.move(to: center)
            let middle = CGPoint(
                x: center.x + cos(angle + 0.12) * radius * 0.48,
                y: center.y + sin(angle + 0.12) * radius * 0.48)
            path.line(to: middle)
            path.line(to: CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius))
            path.stroke()
        }
    }
}
