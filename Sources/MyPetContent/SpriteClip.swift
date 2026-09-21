import CoreGraphics

public struct SpriteClip {
    public let frames: [CGImage]
    public let fps: Double
    public let looping: Bool

    public init(frames: [CGImage], fps: Double, looping: Bool) {
        self.frames = frames
        self.fps = fps
        self.looping = looping
    }
}

public protocol SpriteClipSource {
    func spriteClip(for name: String) -> SpriteClip?
}
