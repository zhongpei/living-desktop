import AppKit

public final class PetView: NSView {
    public var onMouseDown: ((CGPoint) -> Void)?
    public var onMouseDragged: ((CGPoint) -> Void)?
    public var onMouseUp: ((CGPoint, Bool) -> Void)?
    public var onRightMouseDown: ((CGPoint) -> Void)?

    private let coordinateSpace: any RenderCoordinateSpace
    private let spriteLayer = CALayer()
    private let propLayer = CALayer()
    private var mirrored = false
    private var dragStartX: CGFloat?
    private var dragStartY: CGFloat?

    public init(
        frame: NSRect,
        coordinateSpace: (any RenderCoordinateSpace)? = nil
    ) {
        self.coordinateSpace = coordinateSpace ?? AppKitRenderCoordinateSpace()
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        spriteLayer.contentsGravity = .resize
        spriteLayer.frame = bounds
        layer?.addSublayer(spriteLayer)
        propLayer.contentsGravity = .resize
        propLayer.isHidden = true
        layer?.addSublayer(propLayer)
    }

    required init?(coder: NSCoder) { fatalError("PetView only supports programmatic construction") }
    public override var isFlipped: Bool { true }

    public func display(image: CGImage, mirrored: Bool) {
        spriteLayer.contents = image
        if mirrored != self.mirrored {
            self.mirrored = mirrored
            spriteLayer.transform = mirrored
                ? CATransform3DMakeScale(-1, 1, 1)
                : CATransform3DIdentity
        }
    }

    public func displayProp(image: CGImage?, rect: CGRect) {
        guard let image else {
            propLayer.isHidden = true
            propLayer.contents = nil
            return
        }
        propLayer.isHidden = false
        propLayer.contents = image
        propLayer.frame = rect
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.frame = bounds
        CATransaction.commit()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        let p = flippedGlobalPoint()
        dragStartX = p.x
        dragStartY = p.y
        onMouseDown?(p)
    }

    public override func mouseDragged(with event: NSEvent) { onMouseDragged?(flippedGlobalPoint()) }

    public override func mouseUp(with event: NSEvent) {
        let p = flippedGlobalPoint()
        let travel = hypot(p.x - (dragStartX ?? p.x), p.y - (dragStartY ?? p.y))
        onMouseUp?(p, travel < 4)
    }

    public override func rightMouseDown(with event: NSEvent) { onRightMouseDown?(flippedGlobalPoint()) }

    private func flippedGlobalPoint() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: coordinateSpace.primaryTopY - p.y)
    }
}
