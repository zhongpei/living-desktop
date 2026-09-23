import Foundation

/// Deterministic fixed-step clock for the shared 2D body simulation.
/// Variable render deltas are converted into an ordered range of 60 Hz frames.
public struct BodyFrameAccumulator: Codable, Equatable, Sendable {
    public static let framesPerSecond = 60
    public static let maximumElapsedSeconds = 0.25

    public private(set) var frame: Int64
    private var remainderSeconds: Double

    public init(frame: Int64 = 0, remainderSeconds: Double = 0) {
        self.frame = max(0, frame)
        self.remainderSeconds = max(0, remainderSeconds)
    }

    /// Consumes one render delta and returns the exact body-frame identifiers
    /// that the caller must simulate. Invalid deltas do not move time, and a
    /// single pulse is capped to prevent an unbounded catch-up spiral.
    public mutating func consume(elapsedSeconds: Double) -> Range<Int64> {
        guard elapsedSeconds.isFinite, elapsedSeconds > 0 else {
            return frame..<frame
        }
        remainderSeconds += min(elapsedSeconds, Self.maximumElapsedSeconds)
        let step = 1.0 / Double(Self.framesPerSecond)
        let count = Int((remainderSeconds + 1e-12) / step)
        guard count > 0 else { return frame..<frame }

        remainderSeconds -= Double(count) * step
        let start = frame
        frame += Int64(count)
        return start..<frame
    }
}
