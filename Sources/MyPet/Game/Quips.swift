import Foundation

// Quips —— 文本生成脑不可用时的内置台词兜底（speechEnabled 关闭或模型离线）。
//
// 按意图 × 人格风格取词；教师脑开启时台词由教师脑生成，这里不参与。
// 固定台词只表达角色口吻；屏幕感知原文由脑路日志单独记录。

enum Quips {

    private static let playful: [SpeechIntent: [String]] = [
        .greet: ["嘿嘿，我来啦！", "哈喽哈喽！", "看我！看我！"],
        .commentActivity: ["敲这么快，键盘不会疼吗？", "这波操作可以呀", "又在忙大事情？"],
        .tease: ["就你这手速，急死我了", "摸鱼被抓包了吧～", "偷偷告诉你：我在看你哦"],
        .complain: ["别戳啦！要戳坏了！", "哼，生气了！", "再戳我就赖着不走了"],
        .chatter: ["啦啦啦～", "今天也是元气满满", "咦，那边有什么？"],
    ]

    private static let reserved: [SpeechIntent: [String]] = [
        .greet: ["……来了。", "嗯，你好。", "（悄悄凑近）"],
        .commentActivity: ["还在忙吗？", "夜深了，注意休息。", "（静静看着你工作）"],
        .tease: ["你写这么久，还没写完吗？", "（小声）茶要凉了。", "发呆也是工作的一部分。"],
        .complain: ["……别闹了。", "（幽怨地看了一眼）", "人家会烦的。"],
        .chatter: ["（望着窗外）", "风把它吹歪了。", "花落了多少……"],
    ]

    private static let easygoing: [SpeechIntent: [String]] = [
        .greet: ["你好呀～", "嗨！", "来啦来啦。"],
        .commentActivity: ["加油加油", "忙什么呢？", "看起来很认真。"],
        .tease: ["偷懒一时爽～", "要不要休息一下？", "我在帮你盯着呢。"],
        .complain: ["轻一点嘛。", "讨厌啦。", "让我静静。"],
        .chatter: ["嗯……", "（伸了个懒腰）", "天气不错。"],
    ]

    private static let sharpTease = [
        "这点速度也敢催我？",
        "你忙成这样，结果呢？",
        "别装认真，我都看见了。",
        "这操作，连我都替你着急。",
    ]

    /// 按意图与人格风格取一句（带情绪，供情绪→表演映射）。
    static func speak(for intent: SpeechIntent, personality: Personality,
                      rng: inout SeededGenerator) -> (text: String, emotion: String) {
        let table: [SpeechIntent: [String]]
        if personality.playfulness >= 0.7 {
            table = playful
        } else if personality.chattiness > 1.4 {
            table = reserved
        } else {
            table = easygoing
        }
        let lines = intent == .tease && personality.teasing >= 0.7
            ? sharpTease
            : (table[intent] ?? easygoing[intent] ?? ["……"])
        let text = lines[Int.random(in: 0..<lines.count, using: &rng)]
        let emotion: String
        switch intent {
        case .greet: emotion = personality.playfulness >= 0.7 ? "happy" : "neutral"
        case .commentActivity: emotion = "neutral"
        case .tease: emotion = "teasing"
        case .complain: emotion = personality.chattiness > 1.4 ? "grievance" : "annoyed"
        case .chatter: emotion = "neutral"
        }
        return (text, emotion)
    }

    /// 只取文本的便捷入口。
    static func line(for intent: SpeechIntent, personality: Personality, rng: inout SeededGenerator) -> String {
        speak(for: intent, personality: personality, rng: &rng).text
    }
}
