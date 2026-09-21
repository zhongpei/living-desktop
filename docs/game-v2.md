# game-v2 运行时实现地图

> 状态：实现地图与迁移清单，2026-09-21。
>
> 目标玩法契约见 [gameplay-requirements.md](gameplay-requirements.md)；动作和素材
> 契约见 [action-foundation.md](action-foundation.md)；本文件只说明代码如何承接
> 这些契约，不把目标状态写成已完成状态。

## 1. 四个运行时模块

MyPet 的游戏身体由四个边界组成：

| 模块 | 责任 | 禁止越界 |
|---|---|---|
| World | 窗口、角色、道具、关系、槽位、剧情事实和事件 | 不直接渲染、不被菜单私写 |
| Scene | 场景配方、阶段、claim、释放和抢占 | 不直接改关系或所有权 |
| Needle | 在合法候选集合中选下一步语义动作 | 不输出坐标/系统调用 |
| Action | 把语义动作解析为行为请求、素材候选和完成事件 | 不绕过 Kernel 写世界 |

高层决策脑只产生 Goal；本地脑和规则回退都必须进入同一条 Scene/Needle/Action
链路。教师脑不在抢占或快速反应等待链路中。

## 2. 事件与 tick

外部输入、异步脑结果、动作完成和 AppKit 反馈先进入 EventInbox。GameKernel 在
tick 边界按以下顺序处理：

~~~text
drain events
    → validate epoch / TTL / entity / slot versions
    → resolve priority and preemption
    → advance SceneRunner
    → commit world/relationship/story effects
    → publish render projection
~~~

表现层只能消费 projection 和已提交事件。它不能因为动画结束、节点回调或异步
completion 直接释放槽位、修改关系或转移道具。

纯数据 Harness 使用同一条生产链：`VirtualDesktop → GameEvent → GameKernel →
GoalBrain → SceneRunner → NeedleBrain → ActionRuntime → BehaviorRequest →
GameKernel`。每个 tick 先应用 VirtualDesktop 环境事件，再在 `afterEvents` 边界运行
四段语义链并消费同 tick late request，最后才推进时间和行为；Harness 不启动真实
AppKit、AX、OCR 或 ScreenCaptureKit。

### 2.1 三种正式模拟模式

Harness 的 `--mode` 只有以下三种正式模式。三者共用同一条
`Goal → Scene → Needle → Action → Kernel` 链，模式只替换决策适配器；`existing`
不是绕过链路的旧兼容分支。

| 模式 | Goal | Needle | 用途与通过条件 |
|---|---|---|---|
| `existing` | 当前确定性 Policy/Replay GoalBrain | 当前确定性/Replay NeedleBrain | 控制组和回归基线；证明纯数据链、剧情和 Kernel 不变量 |
| `needle-only` | 确定性 GoalBrain | 真实 CNeedle，返回语义动作 | 不加载 Qwen；必须有真实 CNeedle 调用、合法动作和下游 ActionRuntime/Kernel 结果 |
| `qwen+needle` | 本地 MLX Qwen，只返回 GoalDecision | 真实 CNeedle，只返回语义动作 | 必须同时有有效 Qwen Goal、有效 CNeedle 动作和下游 Kernel 结果 |

真实模式缺模型、模型输出不符合协议或没有有效语义结果时必须失败，不能静默降级
为 `existing`。Qwen 不得输出 `BehaviorRequest`，CNeedle 不得写世界；只有
`ActionRuntime` 可以创建请求，只有 `GameKernel` 可以裁决请求。

剧情也遵守相同边界：`StoryDirector` 只选择已配置的剧情段/节拍，随后由
`SemanticStoryExecutionProvider` 依次调用 GoalBrain、为该节拍建立 SceneRunner
场景、调用 Needle、再由 ActionRuntime 生成带剧情 claims/target/slot 的请求。剧情
验收必须同时看到 `story.goal → story.scene → story.needle → story.action`，至少
完成一个 episode，且没有 story reject/cancel、未提交的关系效果或不变量违例。

三种模式的模型输入、schema、原始输出、选择结果、延迟和 Kernel 终态都写入本地
record；训练数据在本机按原样保存，不做脱敏。该记录仍不能证明真实 AppKit、系统
权限、具体应用会话或最终动画观感。

### 2.2 配置驱动的动作矩阵与经典剧本

`Resources/simulation/catalog.json` 是纯数据虚拟机的动作套件配置。它完整列出动作 ID、
动作族和 capability 门禁，并为模拟角色分别声明：

- `support.mode=all`：逻辑上支持动作全集；
- `support.mode=allowlist`：只支持列出的动作，其余结果必须是 `unsupported`；
- `assets.exactMode=all` / `exactActions` / `fallbackActions`：独立描述当前模拟素材等级。

逻辑支持与素材完成度不得合并：支持动作但没有 exact/fallback 时报告 `missing`；没有角色能力
或不在 allowlist 时报告 `unsupported`。`MyPetHarness simulation-suite` 对每个
`角色 × 动作` 通过 `ActionRuntime → BehaviorRequest → GameKernel` 执行，并运行配置中的经典
多步剧本。同一剧本的全部角色和步骤共享一棵 `GameKernel`，报告保留严格递增的步骤序号，
不能再用逐动作重建世界冒充连续剧情。当前内置套件覆盖 94 个动作、4 类模拟角色、40 个剧本
和 181 个步骤；剧本分为单角色、关系、阻挡、多角色、道具、空间、恢复与教学八类。它验证
逻辑调度、顺序、能力门禁和完成边界，不宣称尚未建模的寻路质量、伤害结果或 WebP 动画观感
已通过。

### 2.3 语义角色卡与内部数值投影

`pet-asset-forge/characters/profiles/*.yml` 是面向人的权威角色卡：八个人格侧面、五项玩法
素质、人格类型、标志行为和玩法能力全部使用受控语言，不保存裸数字。`forge sync-catalog`
校验词典后生成 `Resources/characters/catalog.json`；运行时目录同时保留用户可读的
`semanticProfile` 和供 GoalBrain/NeedleBrain 计算的数值 `personality/aptitudes`。调参修改全局
语义映射，不能逐角色暗改生成目录。

标志行为必须连接玩法候选，例如“破坏障碍、魅力试探、诗意表达”；它只改变选择倾向，仍受
capability、世界状态和 ActionRuntime 裁决。生成目录为每个标志行为附带稳定
`actionCandidates`，Harness 校验这些候选全部属于正式动作词表。生命、体能和 condition 也通过统一投影显示为
“状态良好、轻微受伤、有些疲惫、略显恼怒”等语言状态，并给出动作提示。Harness 的
`simulation-suite` 会同时验收 19 份语义角色卡、数值投影、能力标签和三组状态样本。

## 3. 目录驱动

运行时资源和配置分为：

~~~text
Resources/castgroups/*.json
Resources/castpacks/*.json
Resources/categories/catalog.json
Resources/characters/catalog.json
Resources/relationships/catalog.json
Resources/gameplay/catalog.json
Resources/gameplay/plugins/*.json
ActionCatalog
SceneCatalog
PropCatalog
~~~

角色、玩法、动作入口和设置页都由稳定 ID 的目录投影生成。添加一个新玩法应当
新增目录声明和内置适配器，不复制通用菜单、EventInbox 或 GameKernel。

桌面运行时由 `CastContentLibrary` 读取分类、角色、角色组和关系类型目录，再把
CastPack 解析为 `ResolvedCastPack`。Group 提供基础成员和基础关系，CastPack 只选择
本局成员、道具、槽位、剧情和关系状态覆盖。AppKit CastRuntime 只消费解析结果；目录
缺失或解析失败会禁用角色组模式，不允许原始 CastPack 绕过内容校验。
`PetController` 使用 `profileID` 对应的 `CharacterDefinition.personality`，即使角色临时
复用其他 `visualPackID`，也不会继承素材包角色的人格。原来的按 visualPackID 硬编码
人格仅保留给未进入 Cast 目录的单宠物兼容路径。

角色卡的权威源是 `pet-asset-forge/characters/profiles/*.yml`；`forge sync-catalog` 校验后生成
运行时 `Resources/characters/catalog.json`，后者不得手工编辑。同一角色卡还必须拥有
`DialogueProfile`（资源字段 `dialogue`），用于本地 Qwen 的一句话
角色反应。它随 `profileID` 归属角色，不随 `visualPackID` 或 CastPack。每个角色至少为
`greet/comment_activity/tease/complain/chatter` 预置一条人工审核 few-shot 和一条确定性
fallback。运行时只按已经确定的 `SpeechIntent` 取零条或一条同类 few-shot，不把整套示例
塞给 0.8B 模型；生成不合法或事实越界时使用角色卡 fallback。Qwen 只润色已确定的言语行为，
不产生动作、关系、胜负或其他世界事实。完整契约与实测参数见
[教师体系文档](../../docs/system1-model/teacher.md#157-本地-qwen-的一句话角色反应边界)。
每个角色和每种 SpeechIntent 各有独立前缀 key；内存/硬盘 LRU 默认上限为 6/64，并可由本地
BrainProfile 的 `cache.memory_entries` / `cache.disk_entries` 配置，0 表示禁用对应层。

关系目录定义有向/对称类型及允许状态字段。解析阶段拒绝未知分类、成员、关系类型、
状态字段、剧情参与者和 capability 不匹配；Group membership 本身不会生成关系边。
玩法目录也已落盘并被托盘菜单读取，但 implementationID 只能映射到编译进应用的
六个内置适配器，不能加载任意代码或绕过 EventInbox/GameKernel。

## 4. 动作契约迁移

新的统一动作契约是：

- 24 个普通角色基础动作；
- 6 个公开扩展动作；
- 所有可进入场景/剧组角色的 enter_scene 和 exit_scene；
- window、prop、social、mech、destruction、combat 条件能力包。

当前代码仍存在旧的 ActionCatalog 核心动作列表和 ClipLibrary 对基础包的硬门槛；
因此应按以下顺序迁移：

1. 把语义 ID 和动作族收敛到 ActionCatalog；
2. 为动作声明 preferred clip、fallback 链、资源 claim、循环性和中止规则；
3. 增加 entryProfile/exitProfile 与角色 YAML 覆盖字段；
4. 让 ActionRuntime 返回 exact/fallback/missing 的 Content Verdict；
5. 更新角色操作环，使常用动作直接平铺，生命周期动作只由 SceneRunner 触发；
6. 逐批生成并确认素材，再同步 petpack；
7. 用能力矩阵和真实 AppKit smoke 验收。

在这项迁移完成前，idle/walk 角色仍可作为逻辑降级包运行，但不能称为动作完整。

窗口互动的运行时语义是 perch_window，由角色的 windowPerchProfile 选择直接登上、
攀爬登上、荡到窗台或倚靠窗口；sit 只是可能的最终姿态。正式 taunt 和战斗动作
必须经过 combat 能力过滤。

动作、角色、道具、玩法和特效资源统一使用 id + displayName.zh-Hans +
displayName.en。默认菜单投影 zh-Hans，详情和诊断可显示中文/English。

## 5. SceneRunner 与短回合

SceneRunner 执行声明式场景配方。配方至少有：

- 触发、Goal、目标实体和 PlanEpoch；
- 入场/出场、移动、动作、对话、等待；
- 行为资源 claim 和世界交互 slot claim；
- 可抢占边界；
- exact/fallback/missing 的表现选择；
- 成功、取消、过期、缺资源终态；
- 关系效果、StoryFacts 和特效提交。

标准阶段：

~~~text
prepare → enter/approach → claim → perform → resolve → release → exit/return
~~~

P0/P1 可以打断可中断阶段。释放和所有权转移在下一事件边界定向提交；不能在
表现层清空槽位。

## 6. World、Cast 与空间

WorldState 是唯一事实源，至少包括：

- 角色/机甲/窗口/道具实体；
- 多角色独立根节点和 CastProjection；
- InteractionSlot 与 SpatialAttachment；
- 行为资源 claim；
- RelationshipGraph、StoryFacts 和 EffectState；
- 输入观察、TTL、revision 和 PlanEpoch。

SceneGraph 只表达空间父子、插槽和变换。关系、所有权和剧情事实独立保存。实体
离场必须按生命周期释放占用并摘除根节点；Cast 停止后 SceneGraph 可清空和复用。

缺少视觉包的逻辑成员可以留在剧情和报告中，但不能纳入视觉横向安全框。机甲
专属资源缺失时只显示确定性几何 fallback。

## 7. 输入与脑路

PerceptionHub 和 InputPluginCatalog 将窗口、鼠标、AX、OCR、聊天、编码、浏览器
结果转为生产事件。窗口/前台变化不依赖 OCR/AX；内容 observation 只经统一快照
进入 GoalBrain。

三条通道：

| 通道 | 运行时行为 |
|---|---|
| 抢占 | P0/P1 立即请求或打断，不等待内容和 LLM |
| 快速反应 | 标题/活动先触发本地 Goal，内容可升级 |
| 内容 | 有界、可过期 observation，不能直接执行动作 |

异步脑结果和插件结果必须校验 epoch、来源和 TTL。无 LLM、Needle 模型缺失或
所有脑关闭时，GoalPolicy、Autopilot 和随机闲逛仍是合法降级。

## 8. 关系、剧情与效果

StoryDirector 只选择满足条件的 StoryBeat。StoryBeat 可以要求：

- 角色的 enter/exit；
- 普通基础动作或能力包；
- prop、window、cockpit slot；
- RelationshipGraph 前置条件；
- 成功后的声明式关系效果和 StoryFacts。

StoryHandoff 只有在释放节拍和接收节拍的 prop、角色、slot、剧情代次全部匹配时
才产生表现事件。AppKit 只播放共享投影的短递物插值。

短时特效有独立目录、锚点、TTL 和叠加上限；它不替代破坏事件、关系效果或动作
素材。

窗口破坏至少经过 damage_window/strike_window → WindowDamageEvent →
EffectCatalog 的链路，首批窗口特效为 window_crack、window_bullet_hole、
window_impact_flash、window_shards 和 window_smoke。它们只作用于 MyPet 的窗口
表现层，不写入真实外部窗口。

## 9. 验收分层

### Logic Verdict

Headless Harness 负责验证事件、tick、抢占、epoch、槽位、关系、剧情、入退场、
fallback 和回放。

### Content Verdict

AssetCatalog/ActionRuntime 负责报告普通角色 24+6、enter/exit 和能力包的
exact/fallback/missing。逻辑可运行不等于素材 exact。

### Platform Verdict

真实 AppKit、系统权限、具体应用矩阵、WebP 解码、布局和观感必须另行验收；它不是
纯数据 Harness 的通过结论，也不能由 Logic/Content Verdict 推导。

历史测试记录见 [harness-rounds.md](harness-rounds.md)；纯数据范围和限制见
[game-harness.md](../../game-harness.md)。

## 10. 当前状态

仓库当前已具备目录驱动 Cast/玩法、事件收件箱、Needle/Goal 分层、输入矩阵、
关系/slot/StoryHandoff 和确定性 fallback 的实现基础；动作素材的新契约仍需
迁移。本文不把历史回归数字、headless 通过或几何 fallback 解释为专属素材已完成。

当前四组 CastPack 已使用独立 `groupID`、双语 LocalizedLabel、`profileID`、
entry/exit profile、windowPerchProfile 和 capability；`classics/anime` 只作为
categoryID。旧 string label 和 category-as-group 仅在 decoder 中作为迁移兼容，
新资源不得继续使用该形状。

当前验证基线：完整 `swift test --package-path desktop` 为 `306/306`；`MyPet` 与
`MyPetHarness` 独立构建通过。72,000 tick 模拟、四组 CastPack、目录解析、能力门、
真实本地 Qwen 敌对玩法和 raw 输入日志见
[harness-rounds.md](harness-rounds.md)。

每次实现修改后必须同时更新：

1. 代码的语义目录和运行时覆盖；
2. 角色 YAML 与 qa/curation 文本；
3. asset-audit 的事实表；
4. Logic/Content 验证记录；Platform 只在真实 macOS 专项中记录。

## 完整玩法 Qwen 与教学数据

Qwen 的职责不再仅限于单次 Goal。`MyPetHarness qwen-play` 让本地 Qwen 生成多角色
`QwenPlayPlan` 决策节点图：节点只表达参与者、关系交互意图、成功转移和受阻转移；Qwen
看不到也不能输出窗口、屏幕、坐标、anchor、edge、路线或具体移动。`FastPlayResolver` 把
当前节点与实时 `VirtualPlaySpace` 一起交给快速执行层，后者决定靠近、跳跃、绕行和实际
blocker，并把节点展开为 StoryDirector beats。每个 beat 仍逐角色经过
Goal/Scene/Needle/ActionRuntime，Qwen 不能直接写 WorldState。

节点推进本身也是判别式决策边界：输入是当前节点和当前观察，候选是图中合法的下一节点，
输出是一个 `selectedNodeID`。Harness 保存候选顺序与 fingerprint；Director-S1 训练该选择，
Needle/Action-S1 则训练节点落实后的动作选择，二者不使用自由文本作为监督标签。

敌对角色验收模板已经把“计划是否实现”变成终态断言：A/B 从分离 anchor 出发，快脑在
`push_aside`、`jump_over`、`fight_then_continue` 等候选中解决第三方阻挡，随后完成会合和
`fight`。PASS 同时要求剧情完成、最终同位置、战斗交互完成和 Kernel 零不变量；节点图生成
成功本身不算通过。

教学策略与三种 rollout 模式正交：`--teach none|local-qwen|api-teacher|hybrid`。本地 Qwen
产生 Silver，显式 API 强教师复核后产生 Gold；固定单候选剧情步骤只能是 Diagnostic。
boundary、教师原文、策略选择和执行 Outcome 分开落盘，并用 decision ID 与候选 fingerprint
连接。所有本地原始输入和模型原文按原样保存，不做脱敏。
