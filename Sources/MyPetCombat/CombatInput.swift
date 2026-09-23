import Foundation

public enum CombatButton: String, Codable, CaseIterable, Hashable, Sendable {
    case x, y, z, a, b, c
}

public struct FighterInputFrame: Codable, Equatable, Sendable {
    public var left: Bool
    public var right: Bool
    public var up: Bool
    public var down: Bool
    public var buttons: Set<CombatButton>

    public init(left: Bool = false, right: Bool = false, up: Bool = false, down: Bool = false,
                buttons: Set<CombatButton> = []) {
        self.left = left; self.right = right; self.up = up; self.down = down; self.buttons = buttons
    }

    public static let neutral = FighterInputFrame()

    public func forward(facing: CombatFacing) -> Bool { facing == .right ? right : left }
    public func back(facing: CombatFacing) -> Bool { facing == .right ? left : right }
}

public struct CombatInputBuffer: Codable, Equatable, Sendable {
    public let capacity: Int
    private var storage: [FighterInputFrame]

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
        self.storage = []
    }

    public mutating func push(_ input: FighterInputFrame) {
        storage.append(input)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public var newest: FighterInputFrame { storage.last ?? .neutral }
    public var framesNewestFirst: [FighterInputFrame] { storage.reversed() }
}

public enum CombatDirectionToken: String, Codable, Sendable {
    case neutral, forward, back, up, down, downForward, downBack
}

public struct CombatCommandStep: Codable, Equatable, Sendable {
    public var direction: CombatDirectionToken?
    public var button: CombatButton?
    public var maxGapFrames: Int

    public init(direction: CombatDirectionToken? = nil, button: CombatButton? = nil,
                maxGapFrames: Int = 6) {
        self.direction = direction
        self.button = button
        self.maxGapFrames = max(0, maxGapFrames)
    }
}

public struct CombatCommand: Codable, Equatable, Sendable {
    public var steps: [CombatCommandStep]
    public init(_ steps: [CombatCommandStep]) { self.steps = steps }
    public static func button(_ button: CombatButton) -> CombatCommand {
        CombatCommand([CombatCommandStep(button: button, maxGapFrames: 1)])
    }
}

public enum CombatCommandRecognizer {
    public static func matches(_ command: CombatCommand, buffer: CombatInputBuffer,
                               facing: CombatFacing) -> Bool {
        guard !command.steps.isEmpty else { return false }
        let frames = buffer.framesNewestFirst
        var cursor = 0
        for step in command.steps.reversed() {
            var matched = false
            let limit = min(frames.count, cursor + step.maxGapFrames + 1)
            while cursor < limit {
                if satisfies(step, input: frames[cursor], facing: facing) {
                    matched = true
                    cursor += 1
                    break
                }
                cursor += 1
            }
            if !matched { return false }
        }
        return true
    }

    private static func satisfies(_ step: CombatCommandStep, input: FighterInputFrame,
                                  facing: CombatFacing) -> Bool {
        if let button = step.button, !input.buttons.contains(button) { return false }
        guard let direction = step.direction else { return true }
        switch direction {
        case .neutral: return !input.left && !input.right && !input.up && !input.down
        case .forward: return input.forward(facing: facing) && !input.down
        case .back: return input.back(facing: facing) && !input.down
        case .up: return input.up
        case .down: return input.down && !input.left && !input.right
        case .downForward: return input.down && input.forward(facing: facing)
        case .downBack: return input.down && input.back(facing: facing)
        }
    }
}

/// Converts authored/synthetic commands to the exact input type used by real keyboard play.
/// It intentionally feeds the normal matcher instead of calling moves directly.
public enum CombatCommandSynthesizer {
    public static func frames(for command: CombatCommand, facing: CombatFacing) -> [FighterInputFrame] {
        var result: [FighterInputFrame] = [.neutral]
        for step in command.steps {
            result.append(.neutral)
            var frame = FighterInputFrame.neutral
            if let direction = step.direction {
                switch direction {
                case .neutral: break
                case .forward: facing == .right ? (frame.right = true) : (frame.left = true)
                case .back: facing == .right ? (frame.left = true) : (frame.right = true)
                case .up: frame.up = true
                case .down: frame.down = true
                case .downForward:
                    frame.down = true
                    facing == .right ? (frame.right = true) : (frame.left = true)
                case .downBack:
                    frame.down = true
                    facing == .right ? (frame.left = true) : (frame.right = true)
                }
            }
            if let button = step.button { frame.buttons.insert(button) }
            result.append(frame)
        }
        return result
    }
}
