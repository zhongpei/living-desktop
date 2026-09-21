import Foundation

// App 活动语义 —— 「窗口正式变成游戏地形」的语义半张脸。
//
// 几何半张脸（锚点、可站立面）在 WindowEntity / Anchor；
// 这里回答「这扇窗口在发生什么」：CodeX = coding，微信 = chatting。
// 语义只来自应用名 / bundleID / 窗口标题关键词，全程零权限（不走 AX/OCR）。
//
// 大脑与场景配方都只认 Activity，不认具体应用：新装一个应用，
// 只要在归类表里落进某个 Activity，玩法自动出现，不改任何代码。

/// 用户当前在干什么（粗粒度游戏语义）。
enum AppActivity: String, Equatable {
    case coding
    case writing
    case reading
    case browsing
    case chatting
    case watching
    case designing
    case files
    case music
    case unknown

    /// 人类可读名（进大脑 prompt 与日志）。
    var label: String {
        switch self {
        case .coding: return "coding"
        case .writing: return "writing"
        case .reading: return "reading"
        case .browsing: return "browsing"
        case .chatting: return "chatting"
        case .watching: return "watching"
        case .designing: return "designing"
        case .files: return "organizing files"
        case .music: return "listening to music"
        case .unknown: return "unknown"
        }
    }
}

/// 窗口对宠物提供的玩法接口（WindowEntity 之上的语义层）。
/// 几何类（perch/walk）永远可用；参与类（join_*）由 Activity 推导。
enum Affordance: String, Equatable, CaseIterable {
    case perch        // 站上窗台
    case sit          // 窗口底沿台阶
    case walkOn
    case hang         // 挂在窗沿上（前爪扒沿、身子悬空）
    case observe      // 在旁边看
    case peek         // 扒边看
    case lean
    case joinCoding
    case joinReading
    case joinWriting
    case reactChatting
    case joinWatching

    static func affordances(for activity: AppActivity) -> [Affordance] {
        var base: [Affordance] = [.perch, .sit, .walkOn, .hang, .observe, .peek, .lean]
        switch activity {
        case .coding: base.append(.joinCoding)
        case .reading: base.append(.joinReading)
        case .writing: base.append(.joinWriting)
        case .chatting: base.append(.reactChatting)
        case .watching: base.append(.joinWatching)
        default: break
        }
        return base
    }
}

enum AppActivityCatalog {

    /// 归类表：顺序即优先级（更具体的在前）。零权限可查：owner 来自
    /// CGWindowList，bundleID 来自 NSRunningApplication（运行中的进程免授权）。
    struct Rule {
        /// bundleID 前缀（小写匹配），命中即停。
        var bundlePrefixes: [String]
        /// 进程名精确/前缀匹配（大小写不敏感），bundleID 拿不到时的兜底。
        var ownerNames: [String]
        var activity: AppActivity
    }

    static let rules: [Rule] = [
        // 开发
        Rule(bundlePrefixes: ["com.microsoft.vscode", "com.todesktop.230313mzcz4tvpu3", "com.apple.dt.xcode",
                              "com.jetbrains", "com.sublimetext", "com.panic.nova", "dev.windsurf", "com.tauri.cursor", "com.anthropic.claudefordesktop"],
             ownerNames: ["Code", "Code - Insiders", "Xcode", "Cursor", "Windsurf", "IntelliJ IDEA", "PyCharm", "GoLand", "Sublime Text", "Zed", "Trae"],
             activity: .coding),
        Rule(bundlePrefixes: ["com.apple.terminal", "com.googlecode.iterm2", "com.termius", "io.alacritty", "org.alacritty", "com.mitchellh.ghostty", "net.kovidgoyal.kitty"],
             ownerNames: ["Terminal", "iTerm2", "Ghostty", "Warp", "Kitty", "Alacritty", "Termius"],
             activity: .coding),
        // 写作
        Rule(bundlePrefixes: ["com.apple.notes", "com.apple.pages", "com.microsoft.word", "cn.wps", "com.wps", "md.obsidian", "app.typora", "notion.id", "com.lukilink.luki", "com.apple.freeform"],
             ownerNames: ["Notes", "备忘录", "Pages", "Word", "WPS Office", "Obsidian", "Typora", "Notion", "熊掌记"],
             activity: .writing),
        // 聊天
        Rule(bundlePrefixes: ["com.tencent.xinwechat", "com.tencent.qq", "com.alibaba.dingtalk", "com.ss.iphone.lark", "com.electron.lark", "com.feishu", "com.helios.smartsheet", "com.tinyspeck.slackmacgap"],
             ownerNames: ["微信", "WeChat", "QQ", "钉钉", "DingTalk", "飞书", "Lark", "Telegram", "Slack", "Discord", "企业微信"],
             activity: .chatting),
        // 视频
        Rule(bundlePrefixes: ["com.apple.tv", "tv.plex.player", "com.iqiyi", "com.youku", "com.bz.bilibili"],
             ownerNames: ["TV", "爱奇艺", "优酷", "哔哩哔哩", "bilibili", "PotPlayer", "IINA"],
             activity: .watching),
        // 阅读
        Rule(bundlePrefixes: ["com.apple.preview", "com.apple.books", "com.apple.news", "com.readdle.pdflen", "com.readest"],
             ownerNames: ["Preview", "预览", "Books", "图书", "News", "PDF", "Skim", "Zotero"],
             activity: .reading),
        // 设计
        Rule(bundlePrefixes: ["com.adobe", "com.figma", "com.apple.finder.skip", "com BohemianCoding", "com.sketch"],
             ownerNames: ["Photoshop", "Illustrator", "Figma", "Sketch", "Pixelmator Pro", "Affinity Designer", "Affinity Photo"],
             activity: .designing),
        // 文件
        Rule(bundlePrefixes: ["com.apple.finder", "com.apple.dock.extra"],
             ownerNames: ["Finder", "访达", "Path Finder"],
             activity: .files),
        // 音乐
        Rule(bundlePrefixes: ["com.apple.music", "com.spotify.client", "com.netease.163music", "com.kugou", "com.tencent.karaoke"],
             ownerNames: ["Music", "音乐", "Spotify", "网易云音乐", "QQ音乐"],
             activity: .music),
        // 浏览器放最后：标题关键词再细分 reading/watching。
        Rule(bundlePrefixes: ["com.google.chrome", "com.apple.safari", "org.mozilla.firefox", "company.thebrowser.arc", "com.microsoft.edge", "com.microsoft.edgemac", "com.brave.browser", "com.vivaldi"],
             ownerNames: ["Chrome", "Safari", "Firefox", "Arc", "Edge", "Brave", "Vivaldi"],
             activity: .browsing),
    ]

    /// 浏览器窗口标题里的内容级细分（知乎/文档 → reading，B站/YouTube → watching）。
    private static let titleHints: [(keywords: [String], activity: AppActivity)] = [
        (["bilibili", "哔哩", "youtube", "优酷", "爱奇艺", "腾讯视频", "vimeo", "抖音"], .watching),
        (["知乎", "掘金", "segmentfault", "medium", "github", "stack overflow", "文档", "docs", "新闻", "notion", "blog"], .reading),
        (["微信", "网页版微信", "wx.qq", " messenger", "telegram web"], .chatting),
    ]

    /// 纯函数，离线可测：归类一扇窗口。
    static func classify(owner: String, bundleID: String?, windowTitle: String = "") -> AppActivity {
        let loweredBundle = (bundleID ?? "").lowercased()
        for rule in rules {
            if !loweredBundle.isEmpty, rule.bundlePrefixes.contains(where: { loweredBundle.hasPrefix($0) }) {
                return refine(owner: owner, title: windowTitle, base: rule.activity)
            }
        }
        let loweredOwner = owner.lowercased()
        for rule in rules {
            if rule.ownerNames.contains(where: { loweredOwner == $0.lowercased() || loweredOwner.hasPrefix($0.lowercased()) }) {
                return refine(owner: owner, title: windowTitle, base: rule.activity)
            }
        }
        return .unknown
    }

    /// 浏览器类用窗口标题再细分一次；其余应用标题不参与（避免误判）。
    private static func refine(owner: String, title: String, base: AppActivity) -> AppActivity {
        guard base == .browsing, !title.isEmpty else { return base }
        let lowered = title.lowercased()
        for hint in titleHints where hint.keywords.contains(where: { lowered.contains($0) }) {
            return hint.activity
        }
        return base
    }

    /// 活动 → 该陪它玩什么道具（场景配方按此取材，顺序即偏好）。
    static func preferredProps(for activity: AppActivity) -> [String] {
        switch activity {
        case .coding: return ["laptop"]
        case .writing, .reading: return ["book"]
        case .chatting: return ["phone"]
        case .watching: return ["popcorn"]
        case .music: return ["headphone"]
        default: return []
        }
    }
}
