import AppKit

/// 宠物的渲染视图：layer 承载当前 sprite 帧，朝左时水平镜像（素材只画了朝右的步态）。
/// 位置变化 = 挪整个 NSPanel（零重绘）；只有帧变化才碰 layer.contents。
final class PetView: NSView {

    /// 拖拽 / 点击事件透传给 PetController（翻转全局坐标）。
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint, Bool) -> Void)?
    /// 右键只负责打开角色操作环；左键拖拽/点击语义保持不变。
    var onRightMouseDown: ((CGPoint) -> Void)?

    private let spriteLayer = CALayer()
    /// held 道具合成层（在精灵之上：道具拿在身前）。
    private let propLayer = CALayer()
    private var mirrored = false

    override init(frame: NSRect) {
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

    required init?(coder: NSCoder) {
        fatalError("PetView 只在代码里构建")
    }

    override var isFlipped: Bool { true }

    /// 换帧。mirrored = 面朝左。
    func display(image: CGImage, mirrored: Bool) {
        spriteLayer.contents = image
        if mirrored != self.mirrored {
            self.mirrored = mirrored
            spriteLayer.transform = mirrored
                ? CATransform3DMakeScale(-1, 1, 1)
                : CATransform3DIdentity
        }
    }

    /// held 道具合成（视图本地坐标，isFlipped）。image = nil 即隐藏。
    func displayProp(image: CGImage?, rect: CGRect) {
        guard let image else {
            propLayer.isHidden = true
            propLayer.contents = nil
            return
        }
        propLayer.isHidden = false
        propLayer.contents = image
        propLayer.frame = rect
    }

    /// 实时预览会改面板/视图尺寸（设置窗滑杆）：精灵层跟随新 bounds，
    /// 动作关掉隐式动画（40fps 下每个 mutation 都要即时上屏）。
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.frame = bounds
        CATransaction.commit()
    }

    // ---- 鼠标 ----

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = Self.flippedGlobalPoint(event)
        dragStartX = p.x
        dragStartY = p.y
        onMouseDown?(p)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(Self.flippedGlobalPoint(event))
    }

    override func mouseUp(with event: NSEvent) {
        // 位移极小视为点击（摸摸头），否则是甩出。
        let p = Self.flippedGlobalPoint(event)
        let travel = hypot(
            p.x - (dragStartX ?? p.x),
            p.y - (dragStartY ?? p.y)
        )
        onMouseUp?(p, travel < 4)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(Self.flippedGlobalPoint(event))
    }

    private var dragStartX: CGFloat?
    private var dragStartY: CGFloat?

    private static func flippedGlobalPoint(_ event: NSEvent) -> CGPoint {
        let p = NSEvent.mouseLocation // AppKit 全局，原点左下
        return CGPoint(x: p.x, y: Screens.primaryTopY - p.y)
    }
}
