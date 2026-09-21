import CoreGraphics
import Foundation

/// 序列帧时间线：帧池与时间线分离，每帧独立 hold 时长（由 clip 的 fps 决定）。
/// 只做「播到第几帧」的推进，不含任何 AppKit —— 时钟由外部注入，离线可测。
/// 帧来自 ClipLibrary 懒解码缓存；循环性（loop/once）由 manifest playback 决定，
/// 因此同名调用永远不发生模式切换——`play(x, once:)` 同名失效的旧陷阱结构上不存在了。
final class SpriteAnimator {

    private let library: ClipLibrary

    private(set) var clipName = ""
    private var frames: [CGImage] = []
    private(set) var frameIndex = 0
    private(set) var looping = true

    private var frameMS: Double = 130
    private var holdAccumulator: Double = 0
    private var finished = false

    /// once 型 clip 播完时回调（名字 = 播完的 clip）。
    var onFinish: ((String) -> Void)?

    init(library: ClipLibrary) {
        self.library = library
    }

    var isFinished: Bool { finished && !looping }

    /// 切换 clip。同名重复调用不重置（行走中每帧重下指令是常态）；
    /// once 型播完停在末帧并触发 onFinish。
    func play(_ clip: String, restart: Bool = false) {
        if clip == clipName && !restart { return }
        guard let meta = library.meta(for: clip), let pool = library.frames(for: clip) else { return }
        clipName = clip
        frames = pool
        frameMS = 1000.0 / max(meta.fps, 0.001)
        frameIndex = 0
        holdAccumulator = 0
        looping = library.playback(for: clip) == .loop
        finished = false
    }

    /// 推进时间线。返回值：当前帧、以及这帧画面是否变了（变了才需要重绘）。
    func tick(dt: Double) -> (image: CGImage?, changed: Bool) {
        guard !frames.isEmpty else { return (nil, false) }

        if looping {
            holdAccumulator += dt * 1000
            var changed = false
            while holdAccumulator >= frameMS {
                holdAccumulator -= frameMS
                frameIndex = (frameIndex + 1) % frames.count
                changed = true
            }
            // 超长 dt 兜底：至少让画面动一下。
            if !changed && frameIndex == 0 && holdAccumulator > frameMS {
                changed = true
            }
            return (frames[frameIndex], changed)
        }

        if finished { return (frames[frameIndex], false) }
        holdAccumulator += dt * 1000
        while holdAccumulator >= frameMS && frameIndex < frames.count - 1 {
            holdAccumulator -= frameMS
            frameIndex += 1
        }
        if frameIndex >= frames.count - 1 && holdAccumulator >= frameMS {
            finished = true
            onFinish?(clipName)
        }
        return (frames[frameIndex], true)
    }

    /// 当前帧图（供初次摆上视图用）。
    var currentImage: CGImage? {
        frames.isEmpty ? nil : frames[frameIndex]
    }
}
