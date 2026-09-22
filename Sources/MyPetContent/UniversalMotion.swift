import Foundation

/// Compact three-value sample used by mypet-motion-v1.
///
/// Joints encode normalized x/y/confidence. Bones encode unit direction
/// x/y/confidence. root_screen uses normalized source-frame x/y/confidence.
public struct MotionVector3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(x: Double, y: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        confidence = try values.decode(Double.self)
        guard values.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: values, debugDescription: "motion vector must contain exactly 3 values")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
        try values.encode(confidence)
    }

    public static func lerp(_ a: MotionVector3, _ b: MotionVector3, t: Double) -> MotionVector3 {
        let clamped = min(max(t, 0), 1)
        return MotionVector3(
            x: a.x + (b.x - a.x) * clamped,
            y: a.y + (b.y - a.y) * clamped,
            confidence: a.confidence + (b.confidence - a.confidence) * clamped)
    }
}

public struct UniversalMotionSource: Codable, Equatable, Sendable {
    public var kind: String?
    public var character: String?
    public var action: String?
    public var attempt: Int?
    public var planSHA256: String?
    public var generationMode: String?
    public var seed: Int?
    public var rawFrameCount: Int?

    public init(
        kind: String? = nil,
        character: String? = nil,
        action: String? = nil,
        attempt: Int? = nil,
        planSHA256: String? = nil,
        generationMode: String? = nil,
        seed: Int? = nil,
        rawFrameCount: Int? = nil
    ) {
        self.kind = kind
        self.character = character
        self.action = action
        self.attempt = attempt
        self.planSHA256 = planSHA256
        self.generationMode = generationMode
        self.seed = seed
        self.rawFrameCount = rawFrameCount
    }

    enum CodingKeys: String, CodingKey {
        case kind, character, action, attempt, seed
        case planSHA256 = "plan_sha256"
        case generationMode = "generation_mode"
        case rawFrameCount = "raw_frame_count"
    }
}

public struct UniversalMotionQuality: Codable, Equatable, Sendable {
    public var detectionRate: Double
    public var meanConfidence: Double
    public var minConfidence: Double

    public init(detectionRate: Double, meanConfidence: Double, minConfidence: Double) {
        self.detectionRate = detectionRate
        self.meanConfidence = meanConfidence
        self.minConfidence = minConfidence
    }

    enum CodingKeys: String, CodingKey {
        case detectionRate = "detection_rate"
        case meanConfidence = "mean_confidence"
        case minConfidence = "min_confidence"
    }
}

public struct UniversalMotionFrame: Codable, Equatable, Sendable {
    public var index: Int
    public var time: Double
    public var rootScreen: MotionVector3
    public var torsoScalePixels: Double?
    public var meanConfidence: Double?
    public var joints: [String: MotionVector3?]
    public var bones: [String: MotionVector3?]

    public init(
        index: Int,
        time: Double,
        rootScreen: MotionVector3,
        torsoScalePixels: Double? = nil,
        meanConfidence: Double? = nil,
        joints: [String: MotionVector3?],
        bones: [String: MotionVector3?]
    ) {
        self.index = index
        self.time = time
        self.rootScreen = rootScreen
        self.torsoScalePixels = torsoScalePixels
        self.meanConfidence = meanConfidence
        self.joints = joints
        self.bones = bones
    }

    enum CodingKeys: String, CodingKey {
        case index, time, joints, bones
        case rootScreen = "root_screen"
        case torsoScalePixels = "torso_scale_pixels"
        case meanConfidence = "mean_confidence"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        index = try values.decode(Int.self, forKey: .index)
        time = try values.decode(Double.self, forKey: .time)
        rootScreen = try values.decode(MotionVector3.self, forKey: .rootScreen)
        torsoScalePixels = try values.decodeIfPresent(Double.self, forKey: .torsoScalePixels)
        meanConfidence = try values.decodeIfPresent(Double.self, forKey: .meanConfidence)
        joints = try Self.decodeNullableMap(values, forKey: .joints)
        bones = try Self.decodeNullableMap(values, forKey: .bones)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(index, forKey: .index)
        try values.encode(time, forKey: .time)
        try values.encode(rootScreen, forKey: .rootScreen)
        try values.encodeIfPresent(torsoScalePixels, forKey: .torsoScalePixels)
        try values.encodeIfPresent(meanConfidence, forKey: .meanConfidence)
        try Self.encodeNullableMap(joints, to: &values, forKey: .joints)
        try Self.encodeNullableMap(bones, to: &values, forKey: .bones)
    }

    private static func decodeNullableMap(
        _ values: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [String: MotionVector3?] {
        let nested = try values.nestedContainer(keyedBy: MotionDynamicKey.self, forKey: key)
        var result: [String: MotionVector3?] = [:]
        for name in nested.allKeys {
            if try nested.decodeNil(forKey: name) {
                result[name.stringValue] = .some(nil)
            } else {
                result[name.stringValue] = try nested.decode(MotionVector3.self, forKey: name)
            }
        }
        return result
    }

    private static func encodeNullableMap(
        _ map: [String: MotionVector3?],
        to values: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        var nested = values.nestedContainer(keyedBy: MotionDynamicKey.self, forKey: key)
        for (name, sample) in map {
            guard let codingKey = MotionDynamicKey(stringValue: name) else { continue }
            if let sample {
                try nested.encode(sample, forKey: codingKey)
            } else {
                try nested.encodeNil(forKey: codingKey)
            }
        }
    }
}

public struct UniversalMotionDocument: Codable, Equatable, Sendable {
    public static let currentFormat = "mypet-motion-v1"
    public static let currentSkeleton = "coco17-v1"

    public var format: String
    public var skeleton: String
    public var fps: Double
    public var frameCount: Int
    public var durationSeconds: Double
    public var source: UniversalMotionSource?
    public var quality: UniversalMotionQuality?
    public var frames: [UniversalMotionFrame]

    public init(
        format: String = Self.currentFormat,
        skeleton: String = Self.currentSkeleton,
        fps: Double,
        frameCount: Int? = nil,
        durationSeconds: Double,
        source: UniversalMotionSource? = nil,
        quality: UniversalMotionQuality? = nil,
        frames: [UniversalMotionFrame]
    ) {
        self.format = format
        self.skeleton = skeleton
        self.fps = fps
        self.frameCount = frameCount ?? frames.count
        self.durationSeconds = durationSeconds
        self.source = source
        self.quality = quality
        self.frames = frames
    }

    enum CodingKeys: String, CodingKey {
        case format, skeleton, fps, source, quality, frames
        case frameCount = "frame_count"
        case durationSeconds = "duration_seconds"
    }

    public static func decode(_ data: Data) throws -> UniversalMotionDocument {
        let document = try JSONDecoder().decode(UniversalMotionDocument.self, from: data)
        try document.validate()
        return document
    }

    public static func load(from url: URL) throws -> UniversalMotionDocument {
        try decode(Data(contentsOf: url))
    }

    public func validate() throws {
        guard format == Self.currentFormat else {
            throw UniversalMotionError.unsupportedFormat(format)
        }
        guard skeleton == Self.currentSkeleton else {
            throw UniversalMotionError.unsupportedSkeleton(skeleton)
        }
        guard fps.isFinite, fps > 0 else {
            throw UniversalMotionError.invalidMetadata("fps must be positive")
        }
        guard !frames.isEmpty, frameCount == frames.count else {
            throw UniversalMotionError.invalidMetadata("frame_count does not match frames")
        }
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            throw UniversalMotionError.invalidMetadata("duration_seconds must be non-negative")
        }

        var previousTime = -Double.infinity
        for (position, frame) in frames.enumerated() {
            guard frame.index == position else {
                throw UniversalMotionError.invalidMetadata("frame index must be contiguous")
            }
            guard frame.time.isFinite, frame.time >= previousTime else {
                throw UniversalMotionError.invalidMetadata("frame time must be monotonic")
            }
            previousTime = frame.time
        }
    }
}

public enum UniversalMotionError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unsupportedSkeleton(String)
    case invalidMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "unsupported motion format: \(format)"
        case .unsupportedSkeleton(let skeleton):
            return "unsupported motion skeleton: \(skeleton)"
        case .invalidMetadata(let reason):
            return "invalid motion metadata: \(reason)"
        }
    }
}

private struct MotionDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
