import CoreGraphics
import Foundation
import MyPetContent

/// Pure sprite timeline. Asset discovery and decoding stay behind
/// SpriteClipSource; the renderer only advances already-resolved frames.
public final class SpriteAnimator {
    private let source: any SpriteClipSource
    private var frames: [CGImage] = []
    private var frameMS: Double = 130
    private var holdAccumulator: Double = 0
    private var finished = false

    public private(set) var clipName = ""
    public private(set) var frameIndex = 0
    public private(set) var looping = true
    public var onFinish: ((String) -> Void)?

    public init(source: any SpriteClipSource) {
        self.source = source
    }

    public var isFinished: Bool { finished && !looping }

    public func play(_ clip: String, restart: Bool = false) {
        if clip == clipName && !restart { return }
        guard let resolved = source.spriteClip(for: clip), !resolved.frames.isEmpty else { return }
        clipName = clip
        frames = resolved.frames
        frameMS = 1000.0 / max(resolved.fps, 0.001)
        frameIndex = 0
        holdAccumulator = 0
        looping = resolved.looping
        finished = false
    }

    public func tick(dt: Double) -> (image: CGImage?, changed: Bool) {
        guard !frames.isEmpty else { return (nil, false) }
        if looping {
            holdAccumulator += dt * 1000
            var changed = false
            while holdAccumulator >= frameMS {
                holdAccumulator -= frameMS
                frameIndex = (frameIndex + 1) % frames.count
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

    public var currentImage: CGImage? {
        frames.isEmpty ? nil : frames[frameIndex]
    }
}
