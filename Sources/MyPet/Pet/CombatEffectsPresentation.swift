import AppKit
import MyPet2D
import MyPetCombat
import MyPetRender

/// Read-only AppKit projection for non-actor combat entities.
@MainActor
final class CombatEffectsPresentation {
    private struct Impact {
        let panel: OverlayPanel
        let expiresAt: TimeInterval
    }

    private let coordinateSpace: any RenderCoordinateSpace
    private var projectiles: [String: (OverlayPanel, ProjectileEffectView)] = [:]
    private var impacts: [String: Impact] = [:]

    init(coordinateSpace: (any RenderCoordinateSpace)? = nil) {
        self.coordinateSpace = coordinateSpace ?? AppKitRenderCoordinateSpace()
    }

    func apply(snapshot: CombatWorldSnapshot, events: [CombatEvent]) {
        let liveIDs = Set(snapshot.projectiles.map { $0.entityID.raw })
        for id in Array(projectiles.keys) where !liveIDs.contains(id) {
            projectiles.removeValue(forKey: id)?.0.orderOut(nil)
        }

        for projectile in snapshot.projectiles {
            let entry: (OverlayPanel, ProjectileEffectView)
            if let existing = projectiles[projectile.entityID.raw] {
                entry = existing
            } else {
                let view = ProjectileEffectView(
                    frame: CGRect(x: 0, y: 0, width: 64, height: 40))
                let panel = OverlayPanel(
                    contentView: view,
                    initialFrame: CGRect(x: 0, y: 0, width: 64, height: 40))
                panel.ignoresMouseEvents = true
                panel.level = NSWindow.Level(
                    Int(CGWindowLevelForKey(.floatingWindow)) + 2)
                entry = (panel, view)
                projectiles[projectile.entityID.raw] = entry
            }
            entry.1.projectile = projectile
            entry.1.needsDisplay = true
            entry.0.setFrame(frame(
                x: projectile.position.x, y: projectile.position.y,
                width: 64, height: 40), display: false)
            entry.0.orderFrontRegardless()
        }

        let bodies = Dictionary(
            uniqueKeysWithValues: snapshot.bodies.map { ($0.actorID.raw, $0) })
        let now = ProcessInfo.processInfo.systemUptime
        for event in events {
            let point: CombatPoint?
            switch event.kind {
            case .hit, .blocked:
                point = event.targetID.flatMap { bodies[$0.raw]?.position }
            case .clash, .assistEntered:
                point = bodies[event.actorID.raw]?.position
            default:
                point = nil
            }
            guard let point else { continue }
            let key = "\(event.frame):\(event.kind.rawValue):\(event.actorID.raw):\(event.targetID?.raw ?? "-")"
            guard impacts[key] == nil else { continue }
            let view = ImpactEffectView(
                frame: CGRect(x: 0, y: 0, width: 72, height: 72),
                kind: event.kind)
            let panel = OverlayPanel(
                contentView: view,
                initialFrame: frame(
                    x: point.x, y: point.y - 40, width: 72, height: 72))
            panel.ignoresMouseEvents = true
            panel.level = NSWindow.Level(
                Int(CGWindowLevelForKey(.floatingWindow)) + 3)
            panel.orderFrontRegardless()
            impacts[key] = Impact(
                panel: panel,
                expiresAt: now + (event.kind == .assistEntered ? 0.45 : 0.20))
        }

        let expired = impacts.compactMap { key, impact in
            impact.expiresAt <= now ? key : nil
        }
        for key in expired {
            impacts.removeValue(forKey: key)?.panel.orderOut(nil)
        }
    }

    func stop() {
        projectiles.values.forEach { $0.0.orderOut(nil) }
        impacts.values.forEach { $0.panel.orderOut(nil) }
        projectiles.removeAll()
        impacts.removeAll()
    }

    private func frame(
        x: Double, y: Double, width: CGFloat, height: CGFloat
    ) -> CGRect {
        coordinateSpace.appKitRect(
            flippedTop: CGFloat(y) - height / 2,
            x: CGFloat(x) - width / 2,
            width: width, height: height)
    }
}

@MainActor
private final class ProjectileEffectView: NSView {
    var projectile: CombatProjectileSnapshot?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let projectile else { return }
        let resource = projectile.visualResourceID.lowercased()
        let color: NSColor
        let glyph: String
        if resource.contains("petal") || resource.contains("flower") {
            color = .systemPink; glyph = "✿"
        } else if resource.contains("bowl") || resource.contains("stone") {
            color = .systemOrange; glyph = "●"
        } else {
            color = .systemCyan; glyph = "✦"
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let length = max(0.001, hypot(projectile.velocity.x, projectile.velocity.y))
        let dx = CGFloat(projectile.velocity.x / length)
        let dy = CGFloat(projectile.velocity.y / length)

        let trail = NSBezierPath()
        trail.move(to: CGPoint(x: center.x - dx * 26, y: center.y - dy * 26))
        trail.line(to: CGPoint(x: center.x - dx * 3, y: center.y - dy * 3))
        trail.lineWidth = 5
        color.withAlphaComponent(0.22).setStroke()
        trail.stroke()

        let core = NSBezierPath()
        core.move(to: CGPoint(x: center.x - dx * 17, y: center.y - dy * 17))
        core.line(to: center)
        core.lineWidth = 2
        color.withAlphaComponent(0.9).setStroke()
        core.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .bold),
            .foregroundColor: color,
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        (glyph as NSString).draw(
            at: CGPoint(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2),
            withAttributes: attributes)
    }
}

@MainActor
private final class ImpactEffectView: NSView {
    let kind: CombatEventKind
    override var isFlipped: Bool { true }

    init(frame: NSRect, kind: CombatEventKind) {
        self.kind = kind
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("ImpactEffectView requires programmatic initialization")
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyph: String
        let color: NSColor
        switch kind {
        case .blocked:
            glyph = "◇"; color = .systemBlue
        case .clash:
            glyph = "✧"; color = .systemYellow
        case .assistEntered:
            glyph = "援"; color = .systemPurple
        default:
            glyph = "✦"; color = .systemRed
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: kind == .assistEntered ? 28 : 36,
                weight: .heavy),
            .foregroundColor: color,
        ]
        let size = (glyph as NSString).size(withAttributes: attributes)
        (glyph as NSString).draw(
            at: CGPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}
