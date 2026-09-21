import XCTest
@testable import MyPet
import struct MyPetCore.DialogueProfile

/// 配置档案 v1：代码兜底 + 用户档叠加 + 前缀 hash（brain-local.md §7，离线）。
final class BrainProfileTests: XCTestCase {


    private func tempURL(_ content: String?) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainprofile-\(UUID().uuidString).json")
        if let content {
            try? Data(content.utf8).write(to: url)
        }
        return url
    }

    func testFallbackDefaultsMatchSpec() {
        let profile = BrainProfile.fallback
        XCTAssertEqual(profile.sampling.default.temperature, 0.0)
        XCTAssertEqual(profile.sampling.default.maxTokens, 160)
        XCTAssertEqual(profile.sampling.default.seed, 42)
        XCTAssertEqual(profile.sampling.chat.temperature, 0.3)
        XCTAssertEqual(profile.sampling.chat.topP, 0.8)
        XCTAssertEqual(profile.sampling.chat.topK, 20)
        XCTAssertEqual(profile.sampling.chat.maxTokens, 48)
        XCTAssertNil(profile.sampling.chat.seed)
        XCTAssertEqual(profile.cache.memoryEntries, 6)
        XCTAssertEqual(profile.cache.diskEntries, 64)
    }

    func testSparseOverlayMergesOnlyWrittenKeys() {
        let url = tempURL("""
        {"schema_version":1,
         "sampling":{"default":{"temperature":0.3},"chat":{"temperature":0.6,"max_tokens":72}},
         "prompt":{"rules_extra":["Be extra sleepy."]},
         "personality":{"description":"A lazier cat."}}
        """)
        let profile = BrainProfile.resolved(localURL: url)
        XCTAssertEqual(profile.sampling.default.temperature, 0.3, "写出的键生效")
        XCTAssertEqual(profile.sampling.default.maxTokens, 160, "未写的键保持兜底值")
        XCTAssertEqual(profile.sampling.chat.temperature, 0.6)
        XCTAssertEqual(profile.sampling.chat.maxTokens, 72)
        XCTAssertEqual(profile.sampling.chat.topP, 0.8, "聊天未写的键保持兜底值")
        XCTAssertEqual(profile.prompt.rulesExtra, ["Be extra sleepy."])
        XCTAssertEqual(profile.personality.description, "A lazier cat.")
        XCTAssertEqual(profile.prompt.worldModel, nil)
    }

    func testCacheOverlayClampsAndMemoryLRUEvictsLeastRecent() {
        let profile = BrainProfile.resolved(localURL: tempURL(
            #"{"cache":{"memory_entries":2,"disk_entries":-3}}"#))
        XCTAssertEqual(profile.cache.memoryEntries, 2)
        XCTAssertEqual(profile.cache.diskEntries, 0)

        var cache = BrainMemoryLRU<Int>()
        cache.insert(1, for: "a", capacity: 2)
        cache.insert(2, for: "b", capacity: 2)
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c", capacity: 2)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.order, ["a", "c"])
        cache.trim(capacity: 1)
        XCTAssertEqual(cache.order, ["c"])
        cache.trim(capacity: 0)
        XCTAssertTrue(cache.values.isEmpty)
    }

    func testDiskCachePruneKeepsMostRecentConfiguredCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-cache-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<4 {
            let url = directory.appendingPathComponent("\(index).safetensors")
            try Data([UInt8(index)]).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path)
        }
        BrainCacheManager.pruneDiskCache(maxEntries: 2, directory: directory)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(remaining, ["2.safetensors", "3.safetensors"])
    }

    func testBrokenOverlayFallsBackToDefaults() {
        // 非法 JSON
        XCTAssertEqual(BrainProfile.resolved(localURL: tempURL("{oops")),
                       BrainProfile.fallback)
        // 缺文件
        XCTAssertEqual(BrainProfile.resolved(localURL: tempURL(nil)), BrainProfile.fallback)
        // 非法人格维度被丢弃，其余键照常生效
        let url = tempURL("""
        {"personality":{"traits_override":{"grumpiness":0.9,"social":1.5}},
         "sampling":{"default":{"temperature":0.5}}}
        """)
        let profile = BrainProfile.resolved(localURL: url)
        XCTAssertEqual(profile.personality.traitsOverride, ["social": 1.0],
                       "未知维度忽略；合法维度保留并夹紧到 0~1")
        XCTAssertEqual(profile.sampling.default.temperature, 0.5)
    }

    func testTraitOverrideClampedAndAppliesToPersonality() {
        let url = tempURL("""
        {"personality":{"traits_override":{"social":1.5,"curiosity":0.1}}}
        """)
        let profile = BrainProfile.resolved(localURL: url)
        let applied = profile.applyingTraits(to: .linDaiyu)
        XCTAssertEqual(applied.social, 1.0, "越界值夹紧到 0~1")
        XCTAssertEqual(applied.curiosity, 0.1)
        XCTAssertEqual(applied.playfulness, Personality.linDaiyu.playfulness, "未覆盖维度不动")
    }

    func testTeasingTraitOverrideAppliesToPersonality() {
        let url = tempURL("""
        {"personality":{"traits_override":{"teasing":1.4}}}
        """)
        let profile = BrainProfile.resolved(localURL: url)
        XCTAssertEqual(profile.personality.traitsOverride["teasing"], 1.0)
        XCTAssertEqual(profile.applyingTraits(to: .default).teasing, 1.0, accuracy: 0.001)
    }

    func testPrefixHashTracksPrefixAffectingContentOnly() {
        var a = BrainProfile.fallback
        var b = BrainProfile.fallback
        XCTAssertEqual(a.prefixHash, b.prefixHash, "同配置同 hash")

        b.sampling.default.temperature = 0.9   // 只改采样：hash 必须不变（§7.4）
        XCTAssertEqual(a.prefixHash, b.prefixHash)

        b.prompt.worldModel = "WORLD MODEL: changed."
        XCTAssertNotEqual(a.prefixHash, b.prefixHash, "前缀文本变化 → hash 变化")

        b = a
        b.personality.traitsOverride["social"] = 0.9
        XCTAssertNotEqual(a.prefixHash, b.prefixHash, "人格覆盖 → 前缀变化 → hash 变化")

        // hash 稳定：跨进程可复现（缓存文件命名依赖它）
        XCTAssertEqual(BrainProfile.sha8("abc"), BrainProfile.sha8("abc"))
        XCTAssertEqual(BrainProfile.sha8("abc").count, 8)
    }

    func testGoalBrainSelectionAllowsIndependentAndParallelBrains() {
        XCTAssertEqual(
            GoalBrainSelection.active(localEnabled: true, localAvailable: true,
                                      teacherEnabled: true, teacherAvailable: true),
            [.local, .teacher])
        XCTAssertEqual(
            GoalBrainSelection.runtime(localEnabled: true, localAvailable: true,
                                       teacherEnabled: true, teacherAvailable: true),
            .local)
        XCTAssertEqual(
            GoalBrainSelection.active(localEnabled: true, localAvailable: false,
                                      teacherEnabled: true, teacherAvailable: true),
            [.teacher])
        XCTAssertEqual(
            GoalBrainSelection.runtime(localEnabled: true, localAvailable: false,
                                       teacherEnabled: true, teacherAvailable: true),
            .teacher)
        XCTAssertTrue(
            GoalBrainSelection.active(localEnabled: false, localAvailable: true,
                                      teacherEnabled: false, teacherAvailable: true).isEmpty)
    }

    func testCoordinatorRunsBothBrainsOnOneSnapshotAndKeepsLocalRuntimeResult() {
        let local = StubGoalBrain()
        let teacher = StubGoalBrain()
        let coordinator = GoalBrainCoordinator(local: local, teacher: teacher)
        coordinator.configure(localEnabled: true, teacherEnabled: true, interval: 0...0)
        let input = GoalBrainInput(
            petID: "rei_chibi",
            world: WorldState(capturedAt: 1, activeApp: "Code", windowTitle: "", appActivity: "coding",
                              userActivity: "editing_text", focusRole: "textarea", visibleContext: [],
                              salientUI: [], nearbyWindows: [], recentEvents: []),
            brain: BrainState(), personality: .default, memory: [], traceID: "trace-parallel")
        let student = GoalDecision(goal: .rest, target: nil, activity: nil, style: "sleepy",
                                   speech: nil, speechIntent: nil, memory: nil, why: nil)
        let teacherLabel = GoalDecision(goal: .joinUserActivity, target: "user", activity: "coding",
                                       style: "quiet", speech: nil, speechIntent: nil, memory: nil, why: nil)
        var runtimeResult: (GoalDecision?, GoalBrainSelection.Source?)?

        XCTAssertTrue(coordinator.maybePlan(now: 0, input: input) { decision, source in
            runtimeResult = (decision, source)
        })
        XCTAssertTrue(coordinator.isPending)
        XCTAssertEqual(local.inputs.map(\.traceID), ["trace-parallel"])
        XCTAssertEqual(teacher.inputs.map(\.traceID), ["trace-parallel"])
        XCTAssertEqual(coordinator.runtimeSource, .local)

        teacher.finish(teacherLabel)
        XCTAssertNil(runtimeResult, "教师标签完成不应覆盖运行时结果")
        local.finish(student)
        XCTAssertEqual(runtimeResult?.0, student)
        XCTAssertEqual(runtimeResult?.1, .local)
        XCTAssertFalse(coordinator.isPending)
    }

    func testCoordinatorCanRunTeacherAloneAsRuntimeAndLabel() {
        let local = StubGoalBrain()
        let teacher = StubGoalBrain()
        let coordinator = GoalBrainCoordinator(local: local, teacher: teacher)
        coordinator.configure(localEnabled: false, teacherEnabled: true, interval: 0...0)
        let input = GoalBrainInput(
            petID: "rei_chibi",
            world: WorldState(capturedAt: 1, activeApp: "Code", windowTitle: "", appActivity: "coding",
                              userActivity: "editing_text", focusRole: "textarea", visibleContext: [],
                              salientUI: [], nearbyWindows: [], recentEvents: []),
            brain: BrainState(), personality: .default, memory: [], traceID: "trace-teacher-only")
        let label = GoalDecision(goal: .rest, target: nil, activity: nil, style: "sleepy",
                                 speech: nil, speechIntent: nil, memory: nil, why: nil)
        var runtimeResult: (GoalDecision?, GoalBrainSelection.Source?)?

        XCTAssertTrue(coordinator.maybePlan(now: 0, input: input) { decision, source in
            runtimeResult = (decision, source)
        })
        XCTAssertEqual(local.inputs.count, 0)
        teacher.finish(label)
        XCTAssertEqual(runtimeResult?.0, label)
        XCTAssertEqual(runtimeResult?.1, .teacher)
    }
}

private final class StubGoalBrain: GoalBrain {
    let isAvailable = true
    var inputs: [GoalBrainInput] = []
    private var completions: [(GoalDecision?) -> Void] = []

    func expedite() {}

    @discardableResult
    func plan(input: GoalBrainInput,
              completion: @escaping (GoalDecision?) -> Void) -> Bool {
        inputs.append(input)
        completions.append(completion)
        return true
    }

    @discardableResult
    func requestSpeech(intent: SpeechIntent, world: WorldState, brain: BrainState,
                       personality: Personality, characterID: String,
                       dialogue: DialogueProfile?, traceID: String?,
                       completion: @escaping (SpeechReply?) -> Void) -> Bool {
        false
    }

    func finish(_ decision: GoalDecision?) {
        completions.removeFirst()(decision)
    }
}
