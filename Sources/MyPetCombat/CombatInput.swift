import Foundation

public enum CombatButton: String, Codable, CaseIterable, Hashable, Sendable {
    case x, y, z, a, s, d
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
    public var framesNewestFirst: [FighterInputFrame] { Array(storage.reversed()) }
}

public enum CombatDirectionToken: String, Codable, Sendable {
    case neutral, forward, back, up, down, downForward, downBack
}

public enum CombatButtonTrigger: String, Codable, Sendable {
    case press, hold, release
}

public struct CombatCommandStep: Codable, Equatable, Sendable {
    public var direction: CombatDirectionToken?
    public var button: CombatButton?
    public var simultaneousButtons: Set<CombatButton>
    public var trigger: CombatButtonTrigger
    public var minimumHoldFrames: Int
    public var maxGapFrames: Int

    public init(direction: CombatDirectionToken? = nil, button: CombatButton? = nil,
                simultaneousButtons: Set<CombatButton> = [],
                trigger: CombatButtonTrigger = .press,
                minimumHoldFrames: Int = 0,
                maxGapFrames: Int = 6) {
        self.direction = direction
        self.button = button
        self.simultaneousButtons = simultaneousButtons
        self.trigger = trigger
        self.minimumHoldFrames = max(0, minimumHoldFrames)
        self.maxGapFrames = max(0, maxGapFrames)
    }

    public init(direction: CombatDirectionToken? = nil, buttons: Set<CombatButton>,
                trigger: CombatButtonTrigger = .press,
                minimumHoldFrames: Int = 0, maxGapFrames: Int = 6) {
        self.init(
            direction: direction,
            simultaneousButtons: buttons,
            trigger: trigger,
            minimumHoldFrames: minimumHoldFrames,
            maxGapFrames: maxGapFrames)
    }

    public var requiredButtons: Set<CombatButton> {
        var result = simultaneousButtons
        if let button { result.insert(button) }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case direction, button, simultaneousButtons, trigger, minimumHoldFrames, maxGapFrames
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            direction: try values.decodeIfPresent(CombatDirectionToken.self, forKey: .direction),
            button: try values.decodeIfPresent(CombatButton.self, forKey: .button),
            simultaneousButtons: try values.decodeIfPresent(
                Set<CombatButton>.self, forKey: .simultaneousButtons) ?? [],
            trigger: try values.decodeIfPresent(
                CombatButtonTrigger.self, forKey: .trigger) ?? .press,
            minimumHoldFrames: try values.decodeIfPresent(
                Int.self, forKey: .minimumHoldFrames) ?? 0,
            maxGapFrames: try values.decodeIfPresent(Int.self, forKey: .maxGapFrames) ?? 6)
    }
}

public struct CombatCommand: Codable, Equatable, Sendable {
    public var steps: [CombatCommandStep]
    public init(_ steps: [CombatCommandStep]) { self.steps = steps }
    public static func button(_ button: CombatButton) -> CombatCommand {
        CombatCommand([CombatCommandStep(button: button, maxGapFrames: 1)])
    }
}

public enum CommandMatcher {
    public static func matches(_ command: CombatCommand, buffer: CombatInputBuffer,
                               facing: CombatFacing) -> Bool {
        guard !command.steps.isEmpty else { return false }
        let frames = buffer.framesNewestFirst
        var cursor = 0
        for step in command.steps.reversed() {
            var matched = false
            let limit = min(frames.count, cursor + step.maxGapFrames + 1)
            while cursor < limit {
                if satisfies(step, frames: frames, index: cursor, facing: facing) {
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

    private static func satisfies(_ step: CombatCommandStep, frames: [FighterInputFrame],
                                  index: Int, facing: CombatFacing) -> Bool {
        let input = frames[index]
        let previous = index + 1 < frames.count ? frames[index + 1] : .neutral
        let buttons = step.requiredButtons
        if !buttons.isEmpty {
            let currentPressed = input.buttons.isSuperset(of: buttons)
            let previousPressed = previous.buttons.isSuperset(of: buttons)
            switch step.trigger {
            case .press:
                guard currentPressed && !previousPressed else { return false }
            case .hold:
                guard currentPressed,
                      consecutiveFrames(
                        frames, from: index,
                        matching: { $0.buttons.isSuperset(of: buttons) }) >=
                        max(1, step.minimumHoldFrames) else { return false }
            case .release:
                guard !currentPressed && previousPressed,
                      consecutiveFrames(
                        frames, from: index + 1,
                        matching: { $0.buttons.isSuperset(of: buttons) }) >=
                        max(1, step.minimumHoldFrames) else { return false }
            }
        }
        guard let direction = step.direction else { return true }
        guard directionMatches(direction, input: input, facing: facing) else { return false }
        if step.minimumHoldFrames > 1 {
            return consecutiveFrames(
                frames, from: index,
                matching: { directionMatches(direction, input: $0, facing: facing) }) >=
                step.minimumHoldFrames
        }
        return true
    }

    private static func consecutiveFrames(
        _ frames: [FighterInputFrame],
        from index: Int,
        matching predicate: (FighterInputFrame) -> Bool
    ) -> Int {
        guard index < frames.count else { return 0 }
        var count = 0
        for frame in frames[index...] {
            guard predicate(frame) else { break }
            count += 1
        }
        return count
    }

    private static func directionMatches(_ direction: CombatDirectionToken,
                                         input: FighterInputFrame,
                                         facing: CombatFacing) -> Bool {
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

/// Compatibility spelling retained for v1 callers.
public typealias CombatCommandRecognizer = CommandMatcher
public typealias InputBuffer = CombatInputBuffer
public typealias CommandDefinition = CombatCommand

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
                case .forward:
                    if facing == .right { frame.right = true } else { frame.left = true }
                case .back:
                    if facing == .right { frame.left = true } else { frame.right = true }
                case .up: frame.up = true
                case .down: frame.down = true
                case .downForward:
                    frame.down = true
                    if facing == .right { frame.right = true } else { frame.left = true }
                case .downBack:
                    frame.down = true
                    if facing == .right { frame.left = true } else { frame.right = true }
                }
            }
            frame.buttons.formUnion(step.requiredButtons)
            if step.trigger == .release, !step.requiredButtons.isEmpty {
                result.append(contentsOf: repeatElement(
                    frame, count: max(1, step.minimumHoldFrames)))
                var released = frame
                released.buttons.subtract(step.requiredButtons)
                result.append(released)
            } else {
                let repetitions = step.minimumHoldFrames > 1
                    ? step.minimumHoldFrames : 1
                result.append(contentsOf: repeatElement(frame, count: repetitions))
            }
        }
        return result
    }
}
