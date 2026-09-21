# Needle 3 行动脑：现状与未来工作

> 状态：行动脑已上线（菜单「行动脑」可随时与随机模式切换比较），
> 行为日志和 headless 评估已落盘。生产脑路日志按本地训练规则完整记录结构、计数、感知输入和模型原文。本文档记录**尚未完成**的训练闭环路线，作为后续工作的施工图。

> 玩法动作契约已统一到 [action-foundation.md](action-foundation.md)：普通角色有
> 24 个基础动作、6 个公开扩展，以及由场景生命周期触发的 enter_scene /
> exit_scene。Needle 选择的是语义动作和候选链，不选择具体素材文件；窗口、道具、
> 社交、机甲、战斗和破坏属于条件能力包，窗口停留通过角色化 perch profile 解析。
> 动作的 exact/fallback/missing 由 ActionRuntime 与 Content Verdict 报告，不能由
> 模型日志中的“chosen”推断视觉素材已完成。

## 三种正式 Harness 模式

纯数据验收的三种模式都走同一条
`GoalBrain → SceneRunner → NeedleBrain → ActionRuntime → GameKernel` 链，模式只替换
决策适配器：

| `--mode` | Goal 适配器 | Needle 适配器 | 约束 |
|---|---|---|---|
| `existing` | 当前确定性 Policy/Replay | 当前确定性/Replay | 控制组；不声称调用真实模型 |
| `needle-only` | 确定性 GoalBrain | 真实 CNeedle | 不调用 Qwen；CNeedle 只能返回语义动作 |
| `qwen+needle` | 本地 MLX Qwen | 真实 CNeedle | Qwen 只能返回 GoalDecision，不能产生行为请求 |

真实模式是严格模式：模型缺失、输出无效或没有进入 ActionRuntime/Kernel 都是失败，
不会退回 `existing`。真实输出、模型输入、动态 schema、chosen、延迟和结果按原样
写入本地 record；`rawOutput` 中的原文与适配后的合法 Goal 同时保留，训练数据不做
脱敏。

剧情的 Needle 验收也使用这三种模式。StoryDirector 选择 authored beat 后，
`SemanticStoryExecutionProvider` 依次记录 `story.goal`、`story.scene`、
`story.needle`、`story.action`，再由同一个 GameKernel 确认行为、slot、关系事实和
handoff。多角色 beat 的每一次 CNeedle 调用都保留，不能只保存最后一个 actor。

## 现状（已落地）

- **行动层架构**：`NeedleBrain`（默认）与 `RandomBrain`（兜底/省资源），
  菜单随时切换；模型缺失自动降级随机。
- **动态 enum schema**：每次决策把当前世界的合法取值（窗口实体、交互、
  表演名单）编译进 tool schema 的 enum，由解码语法保证参数合法
  （spike 实测：自由 schema 合法率 1/10 → enum 约束后结构合法 8/8）。
- **双道校验**：语法约束 + `validate` 语义校验（参数必须被快照完全支撑），
  拒绝的调用直接丢弃（该轮发呆），不重试。
- **统一脑路日志**：`~/Library/Application Support/MyPet/brain_trace.jsonl`
  ——目标规划、行动脑决策、兜底、场景结局和记忆都用 `trace_id` 关联；
  `snapshot / model_input / schema / output / chosen / latency_ms` 以及完整感知/模型原文均按 raw 训练记录保存，查看器按业务链路呈现。

## Harness 实测入口

`MyPetHarness` 使用生产 `GameKernel`，可以把行动脑从桌面窗口中隔离出来做可重复验证。
正式三模式入口为：

```bash
swift run MyPetHarness semantic --mode existing \
  --record /tmp/mypet-existing-run

swift run MyPetHarness semantic --mode needle-only \
  --needle-model Resources/needle3.cact \
  --record /tmp/mypet-needle-only-run

swift run MyPetHarness semantic --mode qwen+needle \
  --qwen-model-dir "$HOME/Library/Application Support/MyPet/Models/brain/qwen3.5-0.8b-optiq-4bit" \
  --needle-model Resources/needle3.cact \
  --record /tmp/mypet-qwen-needle-run
```

剧情使用相同的 `--mode`：

```bash
swift run MyPetHarness cast-run Resources/castpacks \
  --pack journey_west --ticks 60 --mode qwen+needle \
  --qwen-model-dir "$HOME/Library/Application Support/MyPet/Models/brain/qwen3.5-0.8b-optiq-4bit" \
  --needle-model Resources/needle3.cact \
  --record /tmp/mypet-cast-qwen-needle
```

记录目录包含 `scenario.json`、`report.json`、`trace.jsonl`、`final-state.json`、
`metrics.json` 和 `brain-decisions.json`。record v5 的 Needle 成功决策还会写入
`trajectoryID / actor / modelInput / schema / chosen / rawOutput`，可由 `system1` 导入器规范化为
actor-centric 训练样本；`outputPreview` 只用于查看，不能替代完整 rawOutput。语义模式会额外写入当前 actor 和 scene step，并且只在
`ActionRuntime` 产生 Kernel request 后标记 `enqueued=true`。这能区分“模型没有响应”“响应被语义校验丢弃”“行为被抢占”
以及“内核产生不变量违例”，不能只看最终动画猜原因。

“可导入”只表示记录满足 Action-S1 的格式边界，不表示它已经是教师标签。这里的
`chosen` 是当前 CNeedle 的自身选择；语义场景又通常把 SceneRunner 已指定的单一步骤
编译成近乎唯一的候选，因此主要用于接线、语法和 Kernel 验证。正式训练数据需要
[教师体系文档](../../docs/system1-model/teacher.md) 定义的独立 Action Teacher 对同一
冻结候选集重标。

剧情通过必须同时满足：`story.goal → story.scene → story.needle → story.action`
有序存在；运行期间至少一个 episode 完成（以 StoryDirector 的历史
`completedEpisodeCount` 为准，而不是依赖会过期的 `/completed` StoryFact）；story
reject/cancel 为零；handoff、关系效果、slot/attachment 和最终不变量均由 Kernel
记录且无违例。最终
`storyStatus=running` 也可以通过，只要此前已经有完整 episode 成功并且当前 episode
没有中断；这允许一小时 soak 在 episode 边界继续运行。

纯数据语义链的验收入口是：

```bash
swift run MyPetHarness semantic --record /tmp/mypet-semantic-run
```

该场景固定经过 `VirtualDesktop → GameKernel → GoalBrain → SceneRunner → NeedleBrain → ActionRuntime`。
环境、权限和传感器都是数据；`ActionRuntime` 只提交普通 `BehaviorRequest`，素材只记录 exact/fallback/missing，结果拆为 `Logic Verdict` 与 `Content Verdict`。它不证明真实 AppKit 权限、具体应用会话或动画观感。

## 已知基线数据（2026-09-20，M 系实测）

| 指标 | 数值 |
|---|---|
| 单次决策延迟（含加载） | 0.2 ~ 0.85s |
| 峰值内存 | ~91MB |
| 决策节奏 | 4~10s 随机间隔 |
| 模型体积 | needle3.cact 33.7MB（不入库，fetch_needle.sh 下载） |
| 裸基座合法率（自由 schema） | 1/10 |
| enum 约束后结构合法率 | 8/8（语义合理 6/8，两个「失败」实为更优选择） |

## 未来工作（按优先级）

### 1. 单会话记录与跨会话归档
决策日志会在当前应用会话持续写入，但应用启动时会清除上一份
`brain_trace.jsonl`；跨会话自动归档尚未完成。开始正式采集前必须先为每个会话保存
稳定的 trajectory/session ID 和独立文件。还需要补充：决策后的**世界反馈**（动作是否真的执行、
执行时长、用户是否打断）——在 `brain_trace.jsonl` 的 outcome 事件中记录即可，
训练时作为 label 质量 signal。

### 2. 独立 Action Teacher 造理想数据
这里不是复用生产高阶 Goal Teacher 的 `GoalDecision`，而是使用独立 Action prompt
和 response schema，让大模型（Qwen27B / API）对冻结的 snapshot + legal options
批量标注「理想 tool call」。完整数据契约见
[teacher.md](../../docs/system1-model/teacher.md)。
形成 (snapshot → call) 训练集。注意 label 要过滤：
- 参数必须被 snapshot 支撑（同 validate 规则）；
- 惩罚重复（recent 3s 内同动作）；
- 保留多样性（同一 snapshot 可多解，采样去重）。

### 3. LoRA fine-tune（~1 天 + 训练时长）
```bash
needle finetune data.jsonl --layers 8   # 按设备承受力选 rung
needle build --lora adapter.safetensors --layers 8 \
    --platform macos-arm64 --out petbrain.cact
```
官方数据：tuned 子网络在 tool-call 任务上 +18~36 分，4 层 rung 即可超过
DeepSeek V4 Flash 的 tool call。fine-tune 后 `confidence` 不再校准
（返回 None），**校验只能靠 validate**——这已是现行架构。

### 4. 浅层导出上线（~半天）
`petbrain.cact` 放入 `Resources/`（fetch_needle.sh 增加对应分支或直接入 LFS），
`NeedleBrain.modelURL()` 的查找顺序天然支持。预期：延迟从 ~0.8s 降到
~0.2s，内存减半。

### 5. 行为评估（持续）
比较两种脑的量化指标（日志已支持）：
- 合法调用率（chosen ≠ invalid 占比）；
- 行为多样性（distinct actions / hour）；
- 打断率（动作被用户触摸/拖拽打断的占比）；
- 模式对比：同一角色在 needle/random 下的以上三项分布。

## 已知边界（设计决策，非缺陷）

- 决策是无状态的（WorldState 是唯一真源）：Needle 会话每轮 reset，
  多宠物共享一个脑（C API 进程级单模型的约束下这也是唯一解）；
- 基座模型的语义质量靠 snapshot 表达力提升（实体描述、状态字段），
  而不是拉长 system prompt；
- C API 单线程：推理在专用串行队列，主循环不阻塞，但同一时刻只有
  一个决策在飞（多宠物按时间片轮流）。

## 教师清洗与 Qwen 完整玩法

Needle 自己的 `chosen` 只是 policy selection，默认 importer 不再把它当教师标签。Harness
在真实决策点保存按序候选和 fingerprint；本地 Qwen 盲标/审计后是 Silver，API 强教师
复核后是 Gold。decision point 暴露 `perform(think)`、`perform(observe)`、`wait()`、
`sleep()` 等多个合法控制选项；普通 authored beat 的唯一动作只保留为 Diagnostic。

`qwen-play` 的 Qwen 是玩法 Director：它输出多角色交互的决策节点、成功分支和受阻分支，
不输出跨窗口路径或具体清障动作。快速层读取节点与实时空间事实，解析 blocker、选择路径并
展开 Scene；Needle 再从该 Scene 的合法动作中决策，由 ActionRuntime/Kernel 执行。因此
“Qwen 组织完整交互逻辑”和“快速脑负责具体实行”同时成立，二者不争夺世界事实所有权。
