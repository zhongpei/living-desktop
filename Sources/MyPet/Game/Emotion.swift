import Foundation

// Emotion → 表演映射（game.md §14：语言和动画结合）。
//
// 教师脑（或内置台词）给出情绪，动画运行时挑一个匹配的短表演——
// 候选表按包内素材降级，缺 clip 就 silently 跳过，不同角色都能演。

enum EmotionGesture {

    /// 情绪词 → 表演 clip 候选（顺序即偏好；空 = 不加表演，光说话）。
    static func clips(for emotion: String) -> [String] {
        switch emotion.lowercased() {
        case "happy", "joy", "excited":
            return ActionCatalog.candidates(for: .happy)
        case "teasing", "smug", "playful":
            return ActionCatalog.candidates(for: .tease)
        case "annoyed", "angry", "grievance":
            return ActionCatalog.candidates(for: .complain)
        case "sleepy", "tired":
            return ActionCatalog.candidates(for: .rest)
        case "shy":
            return ["pull_willow"] + ActionCatalog.candidates(for: .think)
        default:
            return []
        }
    }
}
