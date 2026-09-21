import AppKit
import CoreGraphics
import Foundation
import Vision

// OCR 传感器（生产落地版，2026-09-20 立项后实现）。
//
// 立项依据（brain-v1.md §OCR 实测）：生产配方 = 截图 10ms + 裁剪 + Vision
// accurate 114ms ≈ **124ms ≤ 300ms 预算**，中文消息行可读；fast 档对中文
// 全乱码不可用；裁剪比例对耗时**非单调**，必须按 app 实测标定。
//
// 契约：
// - 按 bundleID/owner → profile 挂载（微信：裁右侧 44% 聊天区 + accurate）；
// - 无 profile 的应用不截屏 —— 感知范围最小化，不是「装了就能截一切」；
// - 屏幕录制权限：preflight 查询 + request 弹授权（「新鲜生效」：勾选后
//   新进程立即生效，无需重启宿主）；
// - **本地原始记录**：OCR observation/input trace 保留识别到的原文；
//   BrainContextSnapshot.visibleContext 的 ≤6 行×60 字符只是模型输入预算，不是脱敏规则。

struct OCRProfile: Equatable {
    /// Vision 识别档位。中文一律 accurate（实测 fast 全乱码）。
    var cropRightFraction: Double?
    var cropLeftFraction: Double?
    var languages: [String]

    static func standard(languages: [String] = ["zh-Hans", "en-US"]) -> OCRProfile {
        OCRProfile(cropRightFraction: nil, cropLeftFraction: nil, languages: languages)
    }
}

enum OCRCatalog {

    /// app profile 表。裁剪数值用 experiments/ocrprobe 按实测标定，别想当然。
    static let profiles: [(bundlePrefixes: [String], owners: [String], profile: OCRProfile)] = [
        // 微信：聊天区在窗口右侧 44%（实测 114ms accurate，中文可读）。
        (["com.tencent.xinwechat"], ["微信", "WeChat"],
         OCRProfile(cropRightFraction: 0.44, cropLeftFraction: nil, languages: ["zh-Hans", "en-US"])),
        // QQ 同布局思路，先按全窗兜底（未标定，先不裁）。
        (["com.tencent.qq"], ["QQ"], .standard()),
        // 常见聊天客户端：未完成布局标定时先做整窗 OCR，仍受插件白名单、
        // TTL 和字符预算约束；后续可为单个客户端替换成更窄的 crop profile。
        (["com.bytedance.feishu", "com.electron.lark", "com.ss.iphone.lark"],
         ["飞书", "Lark"], .standard()),
        // 编码窗口：AX 优先，OCR 作为无障碍树缺失时的内容通道。
        (["com.microsoft.vscode", "com.apple.dt.xcode", "com.todesktop.",
          "dev.windsurf", "com.zed.Zed"],
         ["Code", "Xcode", "Cursor", "Windsurf", "Zed"], .standard()),
        // 浏览器窗口：浏览器页内正文/代码/聊天均可先走整窗 OCR；
        // 精细活动分类仍由标题和 AX 结果决定。
        (["com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
          "company.thebrowser.browser", "com.microsoft.edgemac", "com.brave.browser",
          "com.vivaldi.vivaldi"],
         ["Chrome", "Safari", "Firefox", "Arc", "Edge", "Brave", "Vivaldi"], .standard()),
    ]

    static func profile(owner: String, bundleID: String?) -> OCRProfile? {
        let loweredBundle = (bundleID ?? "").lowercased()
        for entry in profiles {
            if !loweredBundle.isEmpty, entry.bundlePrefixes.contains(where: { loweredBundle.hasPrefix($0) }) {
                return entry.profile
            }
        }
        let loweredOwner = owner.lowercased()
        for entry in profiles {
            if entry.owners.contains(where: { loweredOwner == $0.lowercased() || loweredOwner.hasPrefix($0.lowercased()) }) {
                return entry.profile
            }
        }
        return nil
    }
}

final class OCRSensor {

    private let queue = DispatchQueue(label: "mypet.ocr-sensor", qos: .utility)

    // MARK: 权限

    static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹系统授权框（应用必须先调一次才会出现在屏幕录制列表里）。
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    // MARK: 感知

    /// 截取窗口 → 按 profile 裁剪 → Vision accurate → 文本行（≤maxLines×60 字符）。
    /// 回调主队列；nil = 无权限/截屏失败/无文本。
    func sense(window: WindowEntity, profile: OCRProfile, maxLines: Int = 6,
               completion: @escaping ([String]?) -> Void) {
        guard Self.permissionGranted else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let windowID = window.id
        queue.async {
            let lines = Self.captureAndRecognize(windowID: windowID, profile: profile, maxLines: maxLines)
            DispatchQueue.main.async { completion(lines) }
        }
    }

    // MARK: 内部（静态纯函数，便于离线测试裁剪逻辑）

    /// 窗口截图（翻转坐标的世界直接用 CG window id）。
    static func capture(windowID: CGWindowID) -> CGImage? {
        // CGWindowListCreateImage 在 macOS 14+ 被标记废弃，但 ScreenCaptureKit 的
        // 流式 API 对一次性截图太重；deployment target 13 下此调用稳定可用。
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]]
        guard let info = list?.first, info[kCGWindowIsOnscreen as String] as? Bool == true else { return nil }
        let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.bestResolution, .boundsIgnoreFraming])
        return image
    }

    /// 按 profile 裁剪。cropRightFraction = 保留窗口**右侧**宽度比例
    /// （微信聊天区在右侧：0.44 = 保留右侧 44%）；cropLeftFraction 同理取左侧。
    static func crop(_ image: CGImage, profile: OCRProfile) -> CGImage {
        let w = image.width
        let h = image.height
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        if let rightFrac = profile.cropRightFraction {
            let keepW = Int(CGFloat(w) * CGFloat(max(0, min(1, rightFrac))))
            rect = CGRect(x: w - keepW, y: 0, width: keepW, height: h)
        } else if let leftFrac = profile.cropLeftFraction {
            let keepW = Int(CGFloat(w) * CGFloat(max(0, min(1, leftFrac))))
            rect = CGRect(x: 0, y: 0, width: keepW, height: h)
        }
        guard let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    /// Vision 文本识别（accurate 档；中文可读性的实测结论决定不提供 fast 选项）。
    static func recognize(_ image: CGImage, languages: [String], maxLines: Int) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(60)) }
        return Array(lines.prefix(maxLines))
    }

    static func captureAndRecognize(windowID: CGWindowID, profile: OCRProfile, maxLines: Int) -> [String]? {
        guard let image = capture(windowID: windowID) else { return nil }
        let cropped = crop(image, profile: profile)
        let lines = recognize(cropped, languages: profile.languages, maxLines: maxLines)
        return lines.isEmpty ? nil : lines
    }
}
