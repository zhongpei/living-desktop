import Foundation
import MyPetCore

/// 多角色共享的外界感知总线。
///
/// WindowWorld、AX 和 OCR 都是桌面级事实，不应该按角色复制。单宠物模式
/// 将事件投递到自己的 GameKernel；角色组则由 owner 投递到 CastRuntime 的
/// 共享 kernel。`ownerID` 只决定谁负责轮询和发起传感器请求。
final class PerceptionHub {
    let world: WindowWorld
    let sensor: AXSensor
    let ocrSensor: OCRSensor
    let senses: SensesStore

    var sensesPending = false
    var ocrPending = false
    var ocrLines: [String] = []
    var ocrLinesAt: Double?

    private(set) var foregroundRevision = 0
    private var nextEventSequence = 0
    private var events: [(sequence: Int, event: GameEvent)] = []

    /// 启动时由 AppDelegate 指定；角色退场后可即时换 owner。
    var ownerID: EntityID?

    init(ownerID: EntityID? = nil) {
        world = WindowWorld()
        sensor = AXSensor()
        ocrSensor = OCRSensor()
        senses = SensesStore()
        self.ownerID = ownerID
        world.onForegroundChanged = { [weak self] _ in
            self?.foregroundRevision += 1
        }
    }

    /// Shared Cast controllers all observe the same foreground revision, but
    /// only the owner may publish the shared-kernel event. Non-owners still
    /// receive the revision through the shared world and may expedite their
    /// own local brain; they must not increment every actor's epoch again.
    static func shouldPublishSharedKernelEvent(
        usesSharedGameplayKernel: Bool,
        isOwner: Bool
    ) -> Bool {
        !usesSharedGameplayKernel || isOwner
    }

    func appendInputEvent(_ event: GameEvent) {
        nextEventSequence += 1
        events.append((nextEventSequence, event))
        // 只保留有限回放窗口；当前角色都会在主循环中及时消费。
        if events.count > 256 { events.removeFirst(events.count - 256) }
    }

    var latestInputSequence: Int { nextEventSequence }

    func inputEvents(after sequence: Int) -> (events: [GameEvent], latestSequence: Int) {
        (events.filter { $0.sequence > sequence }.map(\.event), nextEventSequence)
    }
}
