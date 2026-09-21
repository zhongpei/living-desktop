import CoreGraphics
import Foundation
import MyPetContent

/// 大脑接缝：PetModel 执行动作，谁决定「做什么」由这一层回答。
/// 现在由 RandomBrain 加权随机填充；将来接大脑模型（Needle）时，
/// 把 DecisionVector → PetIntent 的翻译器替换掉 RandomBrain 即可，底层不动。
enum PetIntent {
    case stroll(CGFloat)      // 走向目标 x
    case walkAlong            // 在当前面上继续散步
    case gesture(String)      // 播一段非循环小动作（actions/ 里的 clip 键）
    case leap(WindowEntity)   // 跃上某扇窗口
    case hop                  // 原地小跳
    case dropOff              // 从窗沿跳下去
    case nothing
}

final class RandomBrain {

    /// 决策间隔（秒）——宠物放空的节奏感。
    var interval: ClosedRange<Double> = 2.5...6.5

    private var nextDecisionAt: Double = 0

    /// 到点了吗（由控制器喂时钟）。
    func isDue(now: Double) -> Bool {
        now >= nextDecisionAt
    }

    private func schedule(after now: Double) {
        nextDecisionAt = now + Double.random(in: interval)
    }

    /// 决策一次。只在宠物闲着时被问（走路/空中/拖拽中不打断）。
    func decide(pet: PetModel, world: WindowWorld, library: ClipLibrary, now: Double) -> PetIntent {
        defer { schedule(after: now) }

        if pet.state == .asleep {
            return .nothing
        }
        guard pet.state == .grounded || pet.state == .perched else {
            return .nothing
        }

        // 表演池：包里全部 actions/*，睡眠类姿态除外（睡是身体状态，不是表演）。
        let gestures = library.actionNames
            .filter { !$0.hasPrefix("sleep") }
            .compactMap { library.action(named: $0) }

        let roll = Double.random(in: 0..<1)
        if pet.onWindow {
            // 栖息在窗台上：散步 / 做动作 / 偶尔跳下去。
            if roll < 0.40 { return .walkAlong }
            if roll < 0.62, let g = gestures.randomElement() { return .gesture(g) }
            if roll < 0.75 { return .dropOff }
            return .nothing
        } else {
            // 地板上：散步 / 做动作 / 跳上窗口。
            if roll < 0.42 {
                // 散步目标：脚下地板段为主，隔壁屏幕有地板延续就把范围扩过去，
                // 宠物因此会主动串门（走到屏边掉下台阶落到隔壁显示器继续走）。
                let span = world.floorSpan(near: pet.x, footY: pet.yFeet)
                var lo = span.left + 60
                var hi = span.right - 60
                if let right = world.floorBeyond(edgeX: span.right, direction: 1) {
                    hi = right.right - 60
                }
                if let left = world.floorBeyond(edgeX: span.left, direction: -1) {
                    lo = left.left + 60
                }
                let target = lo + Double.random(in: 0..<1) * max(10, Double(hi - lo))
                return .stroll(CGFloat(target))
            }
            if roll < 0.60, let g = gestures.randomElement() { return .gesture(g) }
            if roll < 0.80, let w = world.interestingWindow() { return .leap(w) }
            if roll < 0.88 { return .hop }
            return .nothing
        }
    }
}
