import Foundation
import MyPetCore
import MyPetPlatform

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
    private let eventBuffer = PlatformEventBuffer(capacity: 256)

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
        eventBuffer.publish(PlatformEvent(event))
    }

    var latestInputSequence: Int64 { eventBuffer.latestSequence }

    func inputEvents(after sequence: Int64) -> (events: [PlatformEvent], latestSequence: Int64) {
        eventBuffer.events(after: sequence)
    }
}
