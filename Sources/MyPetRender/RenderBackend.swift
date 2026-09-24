import AppKit
import CoreGraphics
import MyPetCore

public struct CombatTeammateHUDSnapshot: Equatable, Sendable {
    public let identity: String
    public let hp: Int
    public let maxHP: Int
    public let knockedOut: Bool

    public init(identity: String, hp: Int, maxHP: Int, knockedOut: Bool) {
        self.identity = identity
        self.hp = max(0, hp)
        self.maxHP = max(1, maxHP)
        self.knockedOut = knockedOut
    }
}

public struct CombatHUDSnapshot: Equatable, Sendable {
    public enum OffscreenDirection: String, Sendable { case left, right, up, down }
    public let identity: String
    public let teamID: String?
    public let hp: Int
    public let delayedHP: Int
    public let maxHP: Int
    public let energy: Int
    public let maxEnergy: Int
    public let active: Bool
    public let offscreenDirection: OffscreenDirection?
    public let knockedOut: Bool
    public let teammates: [CombatTeammateHUDSnapshot]

    public init(
        identity: String = "", teamID: String? = nil,
        hp: Int, delayedHP: Int? = nil, maxHP: Int,
        energy: Int, maxEnergy: Int, active: Bool,
        offscreenDirection: OffscreenDirection? = nil,
        knockedOut: Bool = false,
        teammates: [CombatTeammateHUDSnapshot] = []
    ) {
        self.identity = identity; self.teamID = teamID
        self.hp = max(0, hp); self.maxHP = max(1, maxHP)
        self.delayedHP = min(self.maxHP, max(self.hp, delayedHP ?? hp))
        self.energy = max(0, energy); self.maxEnergy = max(1, maxEnergy)
        self.active = active
        self.offscreenDirection = offscreenDirection
        self.knockedOut = knockedOut
        self.teammates = teammates
    }
}

/// Final, read-only render value. It contains pixels and planned screen-space
/// placement, never a mutable world/body reference.
public struct RenderSnapshot: @unchecked Sendable {
    public let actorID: EntityID
    public let frame: LayoutRect
    public let image: CGImage?
    public let mirrored: Bool
    public let opacity: CGFloat
    public let propImage: CGImage?
    public let propFrame: CGRect
    public let visible: Bool
    public let combatHUD: CombatHUDSnapshot?

    public init(
        actorID: EntityID, frame: LayoutRect, image: CGImage?, mirrored: Bool,
        opacity: CGFloat = 1, propImage: CGImage? = nil,
        propFrame: CGRect = .zero, visible: Bool = true,
        combatHUD: CombatHUDSnapshot? = nil
    ) {
        self.actorID = actorID
        self.frame = frame
        self.image = image
        self.mirrored = mirrored
        self.opacity = opacity
        self.propImage = propImage
        self.propFrame = propFrame
        self.visible = visible
        self.combatHUD = combatHUD
    }
}

@MainActor
public protocol RenderBackend: AnyObject {
    func render(snapshot: RenderSnapshot, interpolation: Double)
}

/// Thin rendering seam between presentation/game state and the concrete macOS renderer.
/// A future Metal renderer only needs to implement this surface contract; combat, story,
/// simulation and content code remain unchanged.
@MainActor
public protocol ActorRenderSurface: AnyObject {
    var alphaValue: CGFloat { get set }
    var onMouseDown: ((CGPoint) -> Void)? { get set }
    var onMouseDragged: ((CGPoint) -> Void)? { get set }
    var onMouseUp: ((CGPoint, Bool) -> Void)? { get set }
    var onRightMouseDown: ((CGPoint) -> Void)? { get set }

    func display(image: CGImage, mirrored: Bool)
    func displayProp(image: CGImage?, rect: CGRect)
    func displayCombatHUD(_ snapshot: CombatHUDSnapshot?)
    func setFrame(_ frame: CGRect)
    func show()
    func hide()
}

@MainActor
public protocol ActorRenderBackend: RenderBackend {
    func makeActorSurface(
        actorID: EntityID,
        initialFrame: CGRect,
        coordinateSpace: any RenderCoordinateSpace
    ) -> any ActorRenderSurface
}

/// First renderer: native AppKit window composition backed by CALayer.
/// This keeps transparent desktop windows cheap and avoids a game-engine dependency,
/// while the protocol above leaves a clean path to Metal/MTKView batching later.
@MainActor
public final class CoreAnimationRenderBackend: ActorRenderBackend {
    private var surfaces: [String: CoreAnimationActorSurface] = [:]
    public init() {}

    public func makeActorSurface(
        actorID: EntityID,
        initialFrame: CGRect,
        coordinateSpace: any RenderCoordinateSpace
    ) -> any ActorRenderSurface {
        let surface = CoreAnimationActorSurface(
            initialFrame: initialFrame, coordinateSpace: coordinateSpace)
        surfaces[actorID.raw] = surface
        return surface
    }

    public func render(snapshot: RenderSnapshot, interpolation: Double) {
        guard let surface = surfaces[snapshot.actorID.raw] else { return }
        surface.alphaValue = snapshot.opacity
        if let image = snapshot.image {
            surface.display(image: image, mirrored: snapshot.mirrored)
        }
        surface.displayProp(image: snapshot.propImage, rect: snapshot.propFrame)
        surface.displayCombatHUD(snapshot.combatHUD)
        surface.setFrame(surface.coordinateSpace.appKitRect(
            flippedTop: CGFloat(snapshot.frame.y),
            x: CGFloat(snapshot.frame.x),
            width: CGFloat(snapshot.frame.width),
            height: CGFloat(snapshot.frame.height)))
        snapshot.visible ? surface.show() : surface.hide()
    }
}

/// Real backend-shaped no-op used by headless simulation and deterministic
/// tests. Keeping the last value makes the boundary inspectable.
@MainActor
public final class NullRenderer: ActorRenderBackend {
    public private(set) var lastSnapshot: RenderSnapshot?
    public private(set) var lastInterpolation: Double?
    public private(set) var renderCount = 0

    public init() {}

    public func makeActorSurface(
        actorID: EntityID,
        initialFrame: CGRect,
        coordinateSpace: any RenderCoordinateSpace
    ) -> any ActorRenderSurface {
        NullActorRenderSurface()
    }

    public func render(snapshot: RenderSnapshot, interpolation: Double) {
        lastSnapshot = snapshot
        lastInterpolation = interpolation
        renderCount += 1
    }
}

@MainActor
private final class NullActorRenderSurface: ActorRenderSurface {
    var alphaValue: CGFloat = 1
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint, Bool) -> Void)?
    var onRightMouseDown: ((CGPoint) -> Void)?
    func display(image: CGImage, mirrored: Bool) {}
    func displayProp(image: CGImage?, rect: CGRect) {}
    func displayCombatHUD(_ snapshot: CombatHUDSnapshot?) {}
    func setFrame(_ frame: CGRect) {}
    func show() {}
    func hide() {}
}

@MainActor
final class CoreAnimationActorSurface: ActorRenderSurface {
    private let panel: OverlayPanel
    private let view: PetView
    private let combatHUD = CombatHUDView()
    let coordinateSpace: any RenderCoordinateSpace

    init(initialFrame: CGRect, coordinateSpace: any RenderCoordinateSpace) {
        self.coordinateSpace = coordinateSpace
        view = PetView(frame: CGRect(origin: .zero, size: initialFrame.size),
                       coordinateSpace: coordinateSpace)
        panel = OverlayPanel(contentView: view, initialFrame: initialFrame)
        combatHUD.frame = CGRect(x: 8, y: max(0, initialFrame.height - 30),
                                 width: max(60, initialFrame.width - 16), height: 26)
        combatHUD.autoresizingMask = [.width, .minYMargin]
        view.addSubview(combatHUD)
    }

    var alphaValue: CGFloat {
        get { panel.alphaValue }
        set { panel.alphaValue = newValue }
    }

    var onMouseDown: ((CGPoint) -> Void)? {
        get { view.onMouseDown }
        set { view.onMouseDown = newValue }
    }
    var onMouseDragged: ((CGPoint) -> Void)? {
        get { view.onMouseDragged }
        set { view.onMouseDragged = newValue }
    }
    var onMouseUp: ((CGPoint, Bool) -> Void)? {
        get { view.onMouseUp }
        set { view.onMouseUp = newValue }
    }
    var onRightMouseDown: ((CGPoint) -> Void)? {
        get { view.onRightMouseDown }
        set { view.onRightMouseDown = newValue }
    }

    func display(image: CGImage, mirrored: Bool) {
        view.display(image: image, mirrored: mirrored)
    }

    func displayProp(image: CGImage?, rect: CGRect) {
        view.displayProp(image: image, rect: rect)
    }

    func displayCombatHUD(_ snapshot: CombatHUDSnapshot?) {
        combatHUD.snapshot = snapshot
        combatHUD.isHidden = snapshot == nil
        combatHUD.needsDisplay = true
    }

    func setFrame(_ frame: CGRect) {
        panel.setFrame(frame, display: false)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}

@MainActor
private final class CombatHUDView: NSView {
    var snapshot: CombatHUDSnapshot?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot else { return }
        let inset = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3).fill()
        let width = max(0, inset.width - 6)
        let hpRatio = CGFloat(snapshot.hp) / CGFloat(snapshot.maxHP)
        let delayedRatio = CGFloat(snapshot.delayedHP) / CGFloat(snapshot.maxHP)
        let energyRatio = CGFloat(snapshot.energy) / CGFloat(snapshot.maxEnergy)
        let hpColor: NSColor = hpRatio > 0.5 ? .systemGreen :
            (hpRatio > 0.2 ? .systemOrange : .systemRed)
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(rect: CGRect(x: inset.minX + 3, y: inset.minY + 9,
                                  width: width * delayedRatio, height: 5)).fill()
        hpColor.setFill()
        NSBezierPath(rect: CGRect(x: inset.minX + 3, y: inset.minY + 3,
                                  width: width * hpRatio, height: 5)).fill()
        let segmentGap: CGFloat = 2
        let segmentWidth = (width - segmentGap * 2) / 3
        for index in 0..<3 {
            let segmentStart = CGFloat(index) / 3
            let fill = min(1, max(0, (energyRatio - segmentStart) * 3))
            NSColor.systemCyan.withAlphaComponent(fill > 0 ? 1 : 0.2).setFill()
            NSBezierPath(rect: CGRect(
                x: inset.minX + 3 + CGFloat(index) * (segmentWidth + segmentGap),
                y: inset.minY + 16, width: segmentWidth * fill, height: 3)).fill()
        }
        if !snapshot.identity.isEmpty {
            let label = snapshot.teamID.map { "\(snapshot.identity) · \($0)" } ?? snapshot.identity
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: snapshot.active ? 7 : 6),
                .foregroundColor: NSColor.white,
            ]
            let textHeight = (label as NSString).size(withAttributes: attributes).height
            (label as NSString).draw(
                in: CGRect(x: inset.minX + 4,
                           y: min(inset.minY + 19, inset.maxY - textHeight),
                           width: max(1, inset.width / 2 - 5), height: textHeight),
                withAttributes: attributes)
        }
        if snapshot.active, !snapshot.teammates.isEmpty {
            let compact = snapshot.teammates.prefix(2).map { teammate in
                let hp = Int((100 * Double(teammate.hp) / Double(teammate.maxHP)).rounded())
                return teammate.knockedOut ? "KO" : "\(hp)%"
            }.joined(separator: " · ")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 6, weight: .medium),
                .foregroundColor: NSColor.systemCyan,
            ]
            let textSize = (compact as NSString).size(withAttributes: attributes)
            (compact as NSString).draw(
                at: CGPoint(x: max(inset.midX, inset.maxX - textSize.width),
                            y: min(inset.minY + 19, inset.maxY - textSize.height)),
                withAttributes: attributes)
        }
        if snapshot.knockedOut {
            ("KO" as NSString).draw(
                at: CGPoint(x: max(inset.minX + 4, inset.midX - 10), y: inset.minY + 1),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14),
                                 .foregroundColor: NSColor.systemRed])
        }
        if let direction = snapshot.offscreenDirection {
            let glyph: String = switch direction {
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            }
            (glyph as NSString).draw(
                at: CGPoint(x: inset.maxX - 13, y: inset.minY + 2),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                 .foregroundColor: NSColor.systemYellow])
        }
        if snapshot.active {
            NSColor.white.setFill()
            NSBezierPath(rect: CGRect(x: inset.minX, y: inset.minY, width: 2, height: inset.height)).fill()
        }
    }
}
