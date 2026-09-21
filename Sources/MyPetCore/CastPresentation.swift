import Foundation

/// Cast 生命周期在规则层和渲染层之间的窄接口。
///
/// CastDirector 只确认“谁在场”；AppKit 不应重新解释 arrivalStyle，
/// 否则云、门、发射和传送会在不同入口产生不同的视觉语义。这个计划
/// 只描述可回放的表现意图，不直接创建窗口、动作或道具。
public enum CastTransitionPhase: String, Codable, Sendable {
    case arrival
    case departure
}

public enum CastTransitionRoute: String, Codable, Sendable {
    case edge
    case overhead
    case doorway
    case launch
    case instant
}

/// A normalized, render-agnostic sample of a cast transition.
///
/// The Core owns the route and timing; AppKit multiplies the normalized
/// offsets by the current safe panel frame. Keeping this value type here makes
/// cloud/door/launch semantics deterministic in the harness without making
/// the Core depend on NSWindow or animation APIs.
public struct CastTransitionPresentation: Codable, Equatable, Sendable {
    public let offsetXRatio: Double
    public let offsetYRatio: Double
    public let opacity: Double

    public init(offsetXRatio: Double, offsetYRatio: Double, opacity: Double) {
        self.offsetXRatio = offsetXRatio
        self.offsetYRatio = offsetYRatio
        self.opacity = min(1, max(0, opacity))
    }
}

public struct CastTransitionPlan: Codable, Equatable, Sendable {
    public let phase: CastTransitionPhase
    public let style: CastArrivalStyle
    /// 渲染层可选用的稳定 cue；没有专属素材时仍可用 actionCandidates 降级。
    public let cue: String
    public let route: CastTransitionRoute
    public let actionCandidates: [String]
    public let durationTicks: Int64

    public init(
        phase: CastTransitionPhase,
        style: CastArrivalStyle,
        cue: String,
        route: CastTransitionRoute,
        actionCandidates: [String],
        durationTicks: Int64
    ) {
        self.phase = phase
        self.style = style
        self.cue = cue
        self.route = route
        self.actionCandidates = actionCandidates
        self.durationTicks = max(1, durationTicks)
    }

    public static func arrival(for style: CastArrivalStyle?) -> CastTransitionPlan {
        make(phase: .arrival, style: style ?? .walk)
    }

    public static func departure(for style: CastArrivalStyle?) -> CastTransitionPlan {
        make(phase: .departure, style: style ?? .walk)
    }

    /// Samples the deterministic visual route at a normalized progress value.
    /// `leadingEdge` is selected by the renderer from the target frame; the
    /// default keeps headless callers deterministic and represents left-entry.
    public func presentation(at progress: Double, leadingEdge: Bool = true) -> CastTransitionPresentation {
        let p = min(1, max(0, progress))
        let eased = p * p * (3 - 2 * p)
        let amount = phase == .arrival ? 1 - eased : eased
        let sign = leadingEdge ? -1.0 : 1.0
        let offsets: (Double, Double)
        switch route {
        case .edge:
            offsets = (sign * amount, 0)
        case .overhead:
            offsets = (0, -amount)
        case .doorway:
            offsets = (-amount, 0)
        case .launch:
            offsets = (0, amount)
        case .instant:
            offsets = (0, 0)
        }
        let opacity: Double
        if route == .instant {
            opacity = phase == .arrival ? eased : 1 - eased
        } else {
            opacity = 1
        }
        return CastTransitionPresentation(
            offsetXRatio: offsets.0,
            offsetYRatio: offsets.1,
            opacity: opacity)
    }

    private static func make(
        phase: CastTransitionPhase,
        style: CastArrivalStyle
    ) -> CastTransitionPlan {
        let actionCandidates: [String]
        let route: CastTransitionRoute
        let cue: String
        let duration: Int64

        switch style {
        case .walk:
            actionCandidates = ["wave", "happy"]
            route = .edge
            cue = phase == .arrival ? "cast.walk_in" : "cast.walk_out"
            duration = 4
        case .cloud:
            actionCandidates = ["jump", "happy"]
            route = .overhead
            cue = phase == .arrival ? "cast.cloud_arrive" : "cast.cloud_depart"
            duration = 5
        case .door:
            actionCandidates = ["wave", "happy"]
            route = .doorway
            cue = phase == .arrival ? "cast.door_arrive" : "cast.door_depart"
            duration = 5
        case .launch:
            actionCandidates = ["jump", "happy"]
            route = .launch
            cue = phase == .arrival ? "cast.launch_arrive" : "cast.launch_depart"
            duration = 4
        case .teleport:
            actionCandidates = ["happy", "jump"]
            route = .instant
            cue = phase == .arrival ? "cast.teleport_arrive" : "cast.teleport_depart"
            duration = 2
        }

        return CastTransitionPlan(
            phase: phase,
            style: style,
            cue: cue,
            route: route,
            actionCandidates: actionCandidates,
            durationTicks: duration)
    }
}
