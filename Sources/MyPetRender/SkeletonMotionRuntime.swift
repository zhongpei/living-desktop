import CoreGraphics
import Foundation
import MyPetContent

/// Target-character proportions. Motion stores directions, while the rig owns
/// actual segment lengths, so one clip can drive differently proportioned art.
public struct SkeletonRig2D: Equatable, Sendable {
    public static let requiredSegments = [
        "spine", "head",
        "left_shoulder", "right_shoulder",
        "left_hip", "right_hip",
        "left_upper_arm", "right_upper_arm",
        "left_forearm", "right_forearm",
        "left_thigh", "right_thigh",
        "left_calf", "right_calf",
    ]

    public var lengths: [String: Double]

    public init(lengths: [String: Double]) throws {
        for name in Self.requiredSegments {
            guard let length = lengths[name], length.isFinite, length > 0 else {
                throw SkeletonMotionRuntimeError.invalidRigSegment(name)
            }
        }
        self.lengths = lengths
    }

    public static func humanoid(
        spine: Double,
        head: Double,
        shoulderHalfWidth: Double,
        hipHalfWidth: Double,
        upperArm: Double,
        forearm: Double,
        thigh: Double,
        calf: Double
    ) throws -> SkeletonRig2D {
        try SkeletonRig2D(lengths: [
            "spine": spine,
            "head": head,
            "left_shoulder": shoulderHalfWidth,
            "right_shoulder": shoulderHalfWidth,
            "left_hip": hipHalfWidth,
            "right_hip": hipHalfWidth,
            "left_upper_arm": upperArm,
            "right_upper_arm": upperArm,
            "left_forearm": forearm,
            "right_forearm": forearm,
            "left_thigh": thigh,
            "right_thigh": thigh,
            "left_calf": calf,
            "right_calf": calf,
        ])
    }
}

public struct RetargetedSkeletonPose: Equatable, Sendable {
    public var time: Double
    /// Source-frame hip position, normalized to [0, 1]-style frame coordinates.
    /// V1 exposes it for future root-motion/contact analysis but does not move
    /// the AppKit actor from it automatically.
    public var rootScreen: CGPoint
    /// Rig-space joints, rooted at (0, 0), +x right and +y down.
    public var joints: [String: CGPoint]

    public init(time: Double, rootScreen: CGPoint, joints: [String: CGPoint]) {
        self.time = time
        self.rootScreen = rootScreen
        self.joints = joints
    }

    public subscript(_ name: String) -> CGPoint? { joints[name] }
}

public enum MotionRetargeter {
    public static func retarget(
        frame: UniversalMotionFrame,
        to rig: SkeletonRig2D
    ) throws -> RetargetedSkeletonPose {
        let root = CGPoint.zero
        let chest = add(root, scaled(try vector(sample(frame.bones, "spine"), named: "spine"), by: try length("spine", rig)))
        let head = add(chest, scaled(try vector(sample(frame.bones, "head"), named: "head"), by: try length("head", rig)))

        let leftShoulder = add(
            chest,
            scaled(
                try vector(sample(frame.bones, "left_shoulder"), named: "left_shoulder"),
                by: try length("left_shoulder", rig)))
        let rightShoulder = add(
            chest,
            scaled(
                try vector(sample(frame.bones, "right_shoulder"), named: "right_shoulder"),
                by: try length("right_shoulder", rig)))

        let leftElbow = add(
            leftShoulder,
            scaled(
                try vector(sample(frame.bones, "left_upper_arm"), named: "left_upper_arm"),
                by: try length("left_upper_arm", rig)))
        let rightElbow = add(
            rightShoulder,
            scaled(
                try vector(sample(frame.bones, "right_upper_arm"), named: "right_upper_arm"),
                by: try length("right_upper_arm", rig)))
        let leftWrist = add(
            leftElbow,
            scaled(
                try vector(sample(frame.bones, "left_forearm"), named: "left_forearm"),
                by: try length("left_forearm", rig)))
        let rightWrist = add(
            rightElbow,
            scaled(
                try vector(sample(frame.bones, "right_forearm"), named: "right_forearm"),
                by: try length("right_forearm", rig)))

        // Hip anchors are represented by normalized joints in mypet-motion-v1.
        // Only their direction from the hip midpoint is reused; target spacing
        // comes from the character rig.
        let leftHip = add(
            root,
            scaled(
                try vector(sample(frame.joints, "left_hip"), named: "left_hip"),
                by: try length("left_hip", rig)))
        let rightHip = add(
            root,
            scaled(
                try vector(sample(frame.joints, "right_hip"), named: "right_hip"),
                by: try length("right_hip", rig)))

        let leftKnee = add(
            leftHip,
            scaled(
                try vector(sample(frame.bones, "left_thigh"), named: "left_thigh"),
                by: try length("left_thigh", rig)))
        let rightKnee = add(
            rightHip,
            scaled(
                try vector(sample(frame.bones, "right_thigh"), named: "right_thigh"),
                by: try length("right_thigh", rig)))
        let leftAnkle = add(
            leftKnee,
            scaled(
                try vector(sample(frame.bones, "left_calf"), named: "left_calf"),
                by: try length("left_calf", rig)))
        let rightAnkle = add(
            rightKnee,
            scaled(
                try vector(sample(frame.bones, "right_calf"), named: "right_calf"),
                by: try length("right_calf", rig)))

        return RetargetedSkeletonPose(
            time: frame.time,
            rootScreen: CGPoint(x: CGFloat(frame.rootScreen.x), y: CGFloat(frame.rootScreen.y)),
            joints: [
                "root": root,
                "chest": chest,
                "head": head,
                "left_shoulder": leftShoulder,
                "right_shoulder": rightShoulder,
                "left_elbow": leftElbow,
                "right_elbow": rightElbow,
                "left_wrist": leftWrist,
                "right_wrist": rightWrist,
                "left_hip": leftHip,
                "right_hip": rightHip,
                "left_knee": leftKnee,
                "right_knee": rightKnee,
                "left_ankle": leftAnkle,
                "right_ankle": rightAnkle,
            ])
    }

    private static func sample(
        _ map: [String: MotionVector3?],
        _ name: String
    ) -> MotionVector3? {
        map[name] ?? nil
    }

    private static func add(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    private static func scaled(_ point: CGPoint, by scalar: Double) -> CGPoint {
        CGPoint(x: point.x * CGFloat(scalar), y: point.y * CGFloat(scalar))
    }

    private static func length(_ name: String, _ rig: SkeletonRig2D) throws -> Double {
        guard let value = rig.lengths[name], value.isFinite, value > 0 else {
            throw SkeletonMotionRuntimeError.invalidRigSegment(name)
        }
        return value
    }

    private static func vector(
        _ value: MotionVector3?,
        named name: String
    ) throws -> CGPoint {
        guard let value else {
            throw SkeletonMotionRuntimeError.missingMotionVector(name)
        }
        let magnitude = hypot(value.x, value.y)
        guard magnitude.isFinite, magnitude > 1e-8 else {
            throw SkeletonMotionRuntimeError.degenerateMotionVector(name)
        }
        return CGPoint(
            x: CGFloat(value.x / magnitude),
            y: CGFloat(value.y / magnitude))
    }
}

/// Stateful sampler for one actor. Multiple actors can share the same immutable
/// UniversalMotionDocument while keeping independent playback time and rigs.
public final class SkeletonMotionPlayer {
    public let document: UniversalMotionDocument
    public let looping: Bool
    public private(set) var elapsed: Double = 0

    public init(document: UniversalMotionDocument, looping: Bool) throws {
        try document.validate()
        self.document = document
        self.looping = looping
    }

    public func reset(to time: Double = 0) {
        elapsed = max(0, time)
    }

    public func tick(dt: Double, rig: SkeletonRig2D) throws -> RetargetedSkeletonPose {
        elapsed = max(0, elapsed + max(0, dt))
        return try sample(at: elapsed, rig: rig)
    }

    public func sample(at time: Double, rig: SkeletonRig2D) throws -> RetargetedSkeletonPose {
        let frame = sampledFrame(at: max(0, time))
        return try MotionRetargeter.retarget(frame: frame, to: rig)
    }

    private func sampledFrame(at time: Double) -> UniversalMotionFrame {
        let count = document.frames.count
        if count == 1 { return document.frames[0] }

        let position: Double
        if looping {
            let cycle = Double(count) / document.fps
            let wrapped = cycle > 0 ? time.truncatingRemainder(dividingBy: cycle) : 0
            position = wrapped * document.fps
        } else {
            position = min(time * document.fps, Double(count - 1))
        }

        let lowerIndex = min(Int(floor(position)), count - 1)
        let upperIndex = looping
            ? (lowerIndex + 1) % count
            : min(lowerIndex + 1, count - 1)
        let fraction = position - floor(position)
        if upperIndex == lowerIndex || fraction <= 0 {
            return document.frames[lowerIndex]
        }
        return interpolate(
            document.frames[lowerIndex],
            document.frames[upperIndex],
            t: fraction,
            logicalTime: time)
    }

    private func interpolate(
        _ a: UniversalMotionFrame,
        _ b: UniversalMotionFrame,
        t: Double,
        logicalTime: Double
    ) -> UniversalMotionFrame {
        UniversalMotionFrame(
            index: a.index,
            time: logicalTime,
            rootScreen: MotionVector3.lerp(a.rootScreen, b.rootScreen, t: t),
            torsoScalePixels: nil,
            meanConfidence: nil,
            joints: interpolateMaps(a.joints, b.joints, t: t),
            bones: interpolateMaps(a.bones, b.bones, t: t))
    }

    private func interpolateMaps(
        _ a: [String: MotionVector3?],
        _ b: [String: MotionVector3?],
        t: Double
    ) -> [String: MotionVector3?] {
        var result: [String: MotionVector3?] = [:]
        for key in Set(a.keys).union(b.keys) {
            let av = a[key] ?? nil
            let bv = b[key] ?? nil
            switch (av, bv) {
            case let (.some(left), .some(right)):
                result[key] = MotionVector3.lerp(left, right, t: t)
            case let (.some(left), .none):
                result[key] = left
            case let (.none, .some(right)):
                result[key] = right
            case (.none, .none):
                result[key] = nil
            }
        }
        return result
    }
}

public enum SkeletonMotionRuntimeError: LocalizedError, Equatable {
    case invalidRigSegment(String)
    case missingMotionVector(String)
    case degenerateMotionVector(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRigSegment(let name):
            return "invalid skeleton rig segment: \(name)"
        case .missingMotionVector(let name):
            return "motion frame is missing vector: \(name)"
        case .degenerateMotionVector(let name):
            return "motion frame has degenerate vector: \(name)"
        }
    }
}

