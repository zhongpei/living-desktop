import CoreGraphics
import Foundation

/// 第一阶段的空间变换：保留桌面运行时的左上原点、y 向下约定。
///
/// 这里刻意没有旋转。桌宠当前的朝向由动作/渲染层控制，空间层只需要
/// 稳定表达位置、跟随和缩放；真正需要旋转素材时再扩展这个值类型。
struct SceneTransform: Equatable {

    var position: CGPoint
    var scale: CGSize

    init(position: CGPoint = .zero,
         scale: CGSize = CGSize(width: 1, height: 1)) {
        self.position = position
        self.scale = scale
    }

    static let identity = SceneTransform()

    /// 把一个局部点映射到当前变换的父空间。
    func applying(to point: CGPoint) -> CGPoint {
        CGPoint(x: position.x + point.x * scale.width,
                y: position.y + point.y * scale.height)
    }

    /// 当前变换作为父变换，接上 child 的局部变换。
    func concatenating(_ child: SceneTransform) -> SceneTransform {
        SceneTransform(
            position: applying(to: child.position),
            scale: CGSize(width: scale.width * child.scale.width,
                          height: scale.height * child.scale.height))
    }

    /// 把一个世界变换换算成当前父变换下的局部变换。
    func localTransform(forWorld world: SceneTransform) throws -> SceneTransform {
        guard abs(scale.width) > .ulpOfOne, abs(scale.height) > .ulpOfOne else {
            throw SceneNodeError.nonInvertibleTransform
        }
        return SceneTransform(
            position: CGPoint(
                x: (world.position.x - position.x) / scale.width,
                y: (world.position.y - position.y) / scale.height),
            scale: CGSize(width: world.scale.width / scale.width,
                          height: world.scale.height / scale.height))
    }
}

enum SceneNodeError: Error, Equatable, CustomStringConvertible {
    case duplicateChild(id: String)
    case cycle
    case notAChild(id: String)
    case socketAlreadyExists(name: String)
    case socketNotFound(name: String)
    case socketOccupied(name: String)
    case nonInvertibleTransform

    var description: String {
        switch self {
        case .duplicateChild(let id): return "duplicate child id: \(id)"
        case .cycle: return "scene node cycle"
        case .notAChild(let id): return "not a child: \(id)"
        case .socketAlreadyExists(let name): return "socket already exists: \(name)"
        case .socketNotFound(let name): return "socket not found: \(name)"
        case .socketOccupied(let name): return "socket occupied: \(name)"
        case .nonInvertibleTransform: return "parent transform cannot be inverted"
        }
    }
}

/// 场景树中的一个纯空间节点。
///
/// 节点不创建窗口、不知道角色状态，也不执行动作。父节点持有子节点，
/// 子节点只弱引用父节点，因此树不会因为父子关系形成引用环。
final class SceneNode: Equatable {

    static func == (lhs: SceneNode, rhs: SceneNode) -> Bool {
        lhs === rhs
    }

    enum Kind: Equatable {
        case entity
        case socket
    }

    let id: String
    let kind: Kind

    private(set) weak var parent: SceneNode?
    private(set) var children: [SceneNode] = []
    private var localTransform: SceneTransform

    init(id: String,
         localPosition: CGPoint = .zero,
         localScale: CGSize = CGSize(width: 1, height: 1)) {
        self.id = id
        self.kind = .entity
        self.localTransform = SceneTransform(position: localPosition, scale: localScale)
    }

    private init(id: String, kind: Kind, localPosition: CGPoint) {
        self.id = id
        self.kind = kind
        self.localTransform = SceneTransform(position: localPosition)
    }

    var localPosition: CGPoint {
        get { localTransform.position }
        set { localTransform.position = newValue }
    }

    var localScale: CGSize {
        get { localTransform.scale }
        set { localTransform.scale = newValue }
    }

    var worldTransform: SceneTransform {
        guard let parent else { return localTransform }
        return parent.worldTransform.concatenating(localTransform)
    }

    var worldPosition: CGPoint { worldTransform.position }
    var worldScale: CGSize { worldTransform.scale }

    func child(withID id: String) -> SceneNode? {
        children.first { $0.id == id }
    }

    func socket(named name: String) -> SceneNode? {
        children.first { $0.kind == .socket && $0.id == name }
    }

    /// 新建一个命名空间节点。socket 是树中的真实节点，不是额外的坐标表。
    @discardableResult
    func addSocket(_ name: String, at position: CGPoint = .zero) throws -> SceneNode {
        guard child(withID: name) == nil else {
            throw SceneNodeError.socketAlreadyExists(name: name)
        }
        let socket = SceneNode(id: name, kind: .socket, localPosition: position)
        try addChild(socket)
        return socket
    }

    /// 添加子节点。新节点的当前局部变换默认保持不变；需要保持世界位置时
    /// 显式传入 keepWorldTransform，通常用于把已有实体移动到新容器。
    @discardableResult
    func addChild(_ child: SceneNode,
                  keepWorldTransform: Bool = false) throws -> SceneNode {
        try child.reparent(to: self, keepWorldTransform: keepWorldTransform)
        return child
    }

    /// 把一个实体吸附到命名 socket。默认是吸附语义：节点原点落在 socket
    /// 原点；需要换父节点但不改变视觉位置时可保留世界变换。
    func attach(_ child: SceneNode,
                toSocket name: String,
                keepWorldTransform: Bool = false) throws {
        guard let socket = socket(named: name) else {
            throw SceneNodeError.socketNotFound(name: name)
        }
        if socket.children.contains(where: { $0 !== child }) {
            throw SceneNodeError.socketOccupied(name: name)
        }
        try child.reparent(to: socket, keepWorldTransform: keepWorldTransform)
        if !keepWorldTransform {
            child.localPosition = .zero
        }
    }

    /// 移除直接子节点。默认保留它离开树前的世界位置。
    func removeChild(_ child: SceneNode,
                     keepWorldTransform: Bool = true) throws {
        guard child.parent === self else {
            throw SceneNodeError.notAChild(id: child.id)
        }
        try child.reparent(to: nil, keepWorldTransform: keepWorldTransform)
    }

    /// 换父节点。默认保持世界变换，避免物品在角色/家具之间切换时瞬移。
    func reparent(to newParent: SceneNode?,
                  keepWorldTransform: Bool = true) throws {
        if newParent === self || (newParent.map { contains($0) } ?? false) {
            throw SceneNodeError.cycle
        }
        if newParent === parent {
            return
        }
        if let newParent,
           newParent.children.contains(where: { $0 !== self && $0.id == id }) {
            throw SceneNodeError.duplicateChild(id: id)
        }
        if let newParent, newParent.kind == .socket,
           newParent.children.contains(where: { $0 !== self }) {
            throw SceneNodeError.socketOccupied(name: newParent.id)
        }

        let worldBefore = worldTransform
        let nextLocal: SceneTransform?
        if keepWorldTransform {
            nextLocal = try (newParent?.worldTransform ?? .identity)
                .localTransform(forWorld: worldBefore)
        } else {
            nextLocal = nil
        }

        let oldParent = parent
        oldParent?.detachDirectChild(self)
        parent = newParent
        newParent?.children.append(self)
        if let nextLocal {
            localTransform = nextLocal
        }
    }

    private func contains(_ candidate: SceneNode) -> Bool {
        if self === candidate { return true }
        return children.contains { $0.contains(candidate) }
    }

    private func detachDirectChild(_ child: SceneNode) {
        children.removeAll { $0 === child }
    }

    fileprivate func collectNodes(withID targetID: String,
                                  into result: inout [SceneNode]) {
        if id == targetID { result.append(self) }
        for child in children {
            child.collectNodes(withID: targetID, into: &result)
        }
    }
}

/// 场景树的最小外壳：统一根节点，并提供确定性的路径查找。
final class SceneGraph {

    let root: SceneNode

    init(rootID: String = "scene") {
        root = SceneNode(id: rootID)
    }

    @discardableResult
    func add(_ node: SceneNode, keepWorldTransform: Bool = false) throws -> SceneNode {
        try root.addChild(node, keepWorldTransform: keepWorldTransform)
        return node
    }

    /// path 相对于 root；如果第一个组件恰好是 root ID，也接受这种写法。
    func node(atPath path: [String]) -> SceneNode? {
        var components = path
        if components.first == root.id {
            components.removeFirst()
        }
        var current = root
        for component in components {
            guard let next = current.child(withID: component) else { return nil }
            current = next
        }
        return current
    }

    func nodes(withID id: String) -> [SceneNode] {
        var result: [SceneNode] = []
        root.collectNodes(withID: id, into: &result)
        return result
    }

    /// Removes every root-level entity while preserving this graph instance.
    /// Cast rebuilds use this at a lifecycle boundary so a new runtime cannot
    /// inherit actor or prop nodes from a previous cast.
    func removeAll(keepWorldTransform: Bool = false) {
        for child in root.children {
            try? root.removeChild(child, keepWorldTransform: keepWorldTransform)
        }
    }
}
