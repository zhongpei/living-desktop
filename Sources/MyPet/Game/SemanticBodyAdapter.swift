import CoreGraphics
import Foundation
import MyPetCore

/// Executes a Core-approved BodyCommand on the AppKit stage. It never owns or
/// advances a scene cursor; completion returns only through BodyResult.
@MainActor
final class SemanticBodyAdapter {
    private struct Active {
        let command: BodyCommand
        let generation: Int
        var waitDueTick: Int64?
    }

    private weak var stage: SceneStaging?
    private let report: (BodyResult) -> Void
    private var active: Active?
    private var generation = 0
    private var activityWindowID: CGWindowID?

    init(stage: SceneStaging, report: @escaping (BodyResult) -> Void) {
        self.stage = stage
        self.report = report
    }

    func bindActivityWindow(_ window: WindowEntity?) {
        activityWindowID = window?.id
    }

    func invalidate() {
        generation += 1
        active = nil
        activityWindowID = nil
    }

    func consume(_ command: BodyCommand, startedAtTick: Int64) {
        generation += 1
        let token = generation
        active = Active(command: command, generation: token)
        guard let stage else { finish(token, success: false); return }
        let intent = command.intent

        if intent.hasPrefix("move_to:") {
            let anchor = String(intent.dropFirst("move_to:".count))
            let resolved: (x: CGFloat, top: Bool, window: WindowEntity?)?
            if anchor == "floor_near" {
                resolved = (stage.floorNearPoint(), false, nil)
            } else if anchor.hasPrefix("@activity."), let activityWindowID {
                let slot = AnchorSlot(rawValue: String(anchor.dropFirst("@activity.".count))) ?? .topCenter
                resolved = stage.resolveAnchor("window_\(activityWindowID).\(slot.rawValue)")
            } else {
                resolved = stage.resolveAnchor(anchor)
            }
            guard let resolved else { finish(token, success: false); return }
            stage.sceneMove(toX: resolved.x, top: resolved.top, window: resolved.window) { [weak self] in
                self?.finish(token, success: true)
            }
        } else if intent.hasPrefix("perform:") {
            let action = String(intent.dropFirst("perform:".count))
            stage.scenePerform([action]) { [weak self] in
                self?.finish(token, success: true)
            }
        } else if intent == "wait" {
            active?.waitDueTick = startedAtTick + max(1, command.durationTicks - 1)
        } else if intent == "put_down" {
            if stage.scenePutDown() {
                stage.scenePerform(["put_down", "nod"]) { [weak self] in
                    self?.finish(token, success: true)
                }
            } else {
                finish(token, success: true)
            }
        } else if intent == "pick_up" {
            if stage.scenePickUp() {
                stage.scenePerform(["pick_up", "happy", "nod"]) { [weak self] in
                    self?.finish(token, success: true)
                }
            } else {
                finish(token, success: true)
            }
        } else if intent.hasPrefix("spawn_prop:") || intent == "clear_props" {
            finish(token, success: true)
        } else if intent.hasPrefix("say:") {
            let value = String(intent.dropFirst("say:".count))
            if let speech = SpeechIntent(rawValue: value) { stage.sceneSay(speech) }
            finish(token, success: true)
        } else if intent == "sleep" {
            stage.sceneSleep()
            finish(token, success: true)
        } else if intent == "leave_scene" {
            finish(token, success: true)
        } else {
            finish(token, success: false)
        }
    }

    func tick(nowTick: Int64) {
        guard let active, let due = active.waitDueTick,
              nowTick >= due else { return }
        finish(active.generation, success: true)
    }

    private func finish(_ token: Int, success: Bool) {
        guard let active, active.generation == token else { return }
        self.active = nil
        report(BodyResult(
            behaviorID: active.command.behaviorID,
            executionToken: active.command.executionToken,
            outcome: success ? .completed : .failed))
    }
}
