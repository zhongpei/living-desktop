import CoreGraphics
import XCTest

@testable import MyPet

/// NeedleBrain 纯函数测试：schema 动态 enum、快照、解析、语义校验。
/// 模型推理本身不进单测（需要 needle3.cact，由冒烟路径覆盖）。
final class NeedleBrainTests: XCTestCase {

    private var facts: NeedleBrain.WorldFacts {
        var facts = NeedleBrain.WorldFacts(
            actor: "lin_daiyu",
            userIdleSeconds: 42)
        facts.goal = (kind: "join_user_activity", activity: "coding", style: "quiet_companion")
        facts.anchors = [("window_17.topRight", 300, "Code", "coding", ["perch", "observe"])]
        facts.scenes = ["coding_companion", "quiet_observer"]
        facts.props = ["laptop", "book"]
        facts.performances = ["wave", "nod", "think"]
        facts.speechIntents = ["greet", "complain"]
        facts.recent = ["wave": 120]
        facts.needs = (energy: 70, boredom: 30, social: 40, stress: 0)
        return facts
    }

    // ---- schema：合法取值编译进 enum ----

    func testToolSchemaContainsDynamicEnums() throws {
        let schema = try JSONSerialization.jsonObject(
            with: Data(NeedleBrain.toolSchema(facts: facts).utf8)
        ) as! [[String: Any]]

        let byName = try schema.reduce(into: [:]) { result, tool in
            let fn = tool["function"] as! [String: Any]
            result[fn["name"] as! String] = fn
        }
        XCTAssertEqual(Set(byName.keys),
                       ["choose_scene", "move_to", "spawn_prop", "perform", "say", "sleep", "wait"])

        let moveTo = byName["move_to"] as! [String: Any]
        let params = (moveTo["parameters"] as! [String: Any])["properties"] as! [String: Any]
        XCTAssertEqual((params["target"] as! [String: Any])["enum"] as? [String], ["window_17.topRight"])

        let scenes = (byName["choose_scene"] as! [String: Any])
        let sparams = (scenes["parameters"] as! [String: Any])["properties"] as! [String: Any]
        XCTAssertEqual((sparams["scene"] as! [String: Any])["enum"] as? [String],
                       ["coding_companion", "quiet_observer"])

        let perform = byName["perform"] as! [String: Any]
        let pparams = (perform["parameters"] as! [String: Any])["properties"] as! [String: Any]
        XCTAssertEqual((pparams["action"] as! [String: Any])["enum"] as? [String], ["nod", "think", "wave"])
    }

    func testInSceneModeOmitsSceneChoiceAndAddsLeave() throws {
        var inScene = facts
        inScene.mode = .inScene
        let schema = try JSONSerialization.jsonObject(
            with: Data(NeedleBrain.toolSchema(facts: inScene).utf8)
        ) as! [[String: Any]]
        let names = Set(schema.map { (($0["function"] as! [String: Any])["name"] as! String) })
        XCTAssertEqual(names, ["wait", "leave_scene", "perform", "say"],
                       "场景决策点只给 continue/leave/插播，不给换场景")
    }

    func testEmptyWorldOmitsEntityTools() throws {
        let empty = NeedleBrain.WorldFacts(actor: "rei", userIdleSeconds: 10)
        let schema = try JSONSerialization.jsonObject(
            with: Data(NeedleBrain.toolSchema(facts: empty).utf8)
        ) as! [[String: Any]]
        let names = Set(schema.map { (($0["function"] as! [String: Any])["name"] as! String) })
        XCTAssertEqual(names, ["sleep", "wait"], "无实体/无表演时不应提供对应工具")
    }

    // ---- 快照 ----

    func testSnapshotCarriesFactsGoalAndQuestion() throws {
        let text = NeedleBrain.snapshot(facts: facts)
        let object = try JSONSerialization.jsonObject(with: Data(text.linesBeforeQuestion().utf8)) as! [String: Any]
        XCTAssertEqual(object["actor"] as? String, "lin_daiyu")
        XCTAssertEqual((object["recent"] as? [String: String])?["wave"], "120s_ago")
        let goal = object["goal"] as? [String: Any]
        XCTAssertEqual(goal?["kind"] as? String, "join_user_activity")
        XCTAssertEqual(goal?["activity"] as? String, "coding")
        XCTAssertTrue(text.hasSuffix("question: choose one appropriate next action"))
    }

    // ---- 解析 + 校验 ----

    func testParseTakesFirstValidCall() {
        let output = """
        {"type":"call","function_calls":[
          {"name":"choose_scene","arguments":{"scene":"coding_companion"}},
          {"name":"move_to","arguments":{"target":"window_17.topRight"}},
          {"name":"say","arguments":{"intent":"greet"}}
        ]}
        """
        let calls = NeedleBrain.parseCalls(output)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0], .chooseScene("coding_companion"))
        XCTAssertEqual(calls[1], .moveTo("window_17.topRight"))
        XCTAssertEqual(calls[2], .say("greet"))
    }

    func testValidateRejectsUngrounded() {
        // 场景不在合法集 → 拒绝。
        XCTAssertFalse(NeedleBrain.validate(.chooseScene("tea_break"), facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.chooseScene("coding_companion"), facts: facts))
        // 未声明锚点 → 拒绝。
        XCTAssertFalse(NeedleBrain.validate(.moveTo("window_99.topLeft"), facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.moveTo("window_17.topRight"), facts: facts))
        // 道具/表演/说话同理。
        XCTAssertFalse(NeedleBrain.validate(.spawnProp("popcorn"), facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.spawnProp("laptop"), facts: facts))
        XCTAssertFalse(NeedleBrain.validate(.perform("bath"), facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.perform("nod"), facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.say("greet"), facts: facts))
        XCTAssertTrue(NeedleBrain.validate(.wait, facts: facts))
        // leave_scene 只在场景决策点合法。
        XCTAssertFalse(NeedleBrain.validate(.leaveScene, facts: facts))
        var inScene = facts
        inScene.mode = .inScene
        XCTAssertTrue(NeedleBrain.validate(.leaveScene, facts: inScene))
    }

    // ---- 菜单文案 ----

    func testBrainTitleReflectsModeAndAvailability() {
        XCTAssertEqual(Tray.brainTitle(enabled: true, available: true), "行动脑：Needle 3 本地模型")
        XCTAssertEqual(Tray.brainTitle(enabled: false, available: true), "行动脑：随机动作（省资源）")
        XCTAssertTrue(Tray.brainTitle(enabled: true, available: false).contains("未找到模型"))
    }

}

private extension String {
    /// 快照正文在 question 行之前（测试解析用）。
    func linesBeforeQuestion() -> String {
        components(separatedBy: "\nquestion:").first ?? self
    }
}
