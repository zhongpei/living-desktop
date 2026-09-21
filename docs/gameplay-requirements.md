# MyPet 玩法需求总规格

> 状态：玩法领域模型与素材契约重构基线，2026-09-21。
>
> 本文定义玩法如何组合；动作语义的唯一清单见
> [action-foundation.md](action-foundation.md)。输入路由见
> [gameplay-input-channels.md](gameplay-input-channels.md)，多角色/关系/剧情见
> [story-and-relationships.md](story-and-relationships.md)，空间事实见
> [scene-graph.md](scene-graph.md)，当前实现映射见 [game-v2.md](game-v2.md)，素材盘点见
> [asset-audit.md](asset-audit.md)。
>
> 本文的“要求”不等于“当前已经有素材或代码”。每个能力都必须分别报告
> Logic Verdict、Content Verdict 和真实桌面验收结果。

## 1. 玩法的统一模型

MyPet 是一个在桌面空间运行的短回合游戏。一个玩法不是一个动画文件，而是：

~~~text
外部事件 / 用户输入
        ↓
玩法策略与 Goal
        ↓
声明式 SceneRecipe
        ↓
Needle 选择语义动作与候选链
        ↓
GameKernel 校验世界、资源和抢占
        ↓
角色 / 窗口 / 道具 / 机甲的可观察表现
~~~

四条边界必须保持稳定：

1. 决策脑只决定想做什么，不输出坐标、动画文件名或系统调用。
2. Needle 行动脑只在当前合法动作集合中选择下一步语义动作。
3. GameKernel 拥有 tick、事件、占用、关系效果和剧情事实的写入权。
4. 表现层只执行已提交的行为和短时特效，不反向修改世界所有权。

玩法插件是“配置元数据 + 编译进应用的内置实现”，不是任意动态代码。它只能提出
语义场景、行为请求或事件，所有结果都必须回到 EventInbox，在 tick 边界由
GameKernel 消费。

## 2. 目录和运行时真相

配置目录负责发现和选择，运行时内核负责事实：

~~~text
Resources/castgroups/*.json          角色组与分类投影
Resources/castpacks/*.json           预制剧组、关系、舞台与剧情
Resources/gameplay/catalog.json      玩法组和排序
Resources/gameplay/plugins/*.json    玩法插件声明
ActionCatalog / SceneCatalog         内置语义动作与场景配方
PropCatalog                          内置道具、插槽与降级
EventInbox / GameKernel              唯一的运行时写入边界
~~~

菜单不得从 Swift 源码中的角色名、玩法名或分类名拼接。角色、剧组、玩法、设置
和动作入口均由稳定 ID 的目录投影生成。旧的 classics / anime 只能作为
categoryID 迁移来源，不能继续充当可玩的角色组。

当前实现中的解析顺序固定为：

~~~text
CategoryCatalog + CharacterCatalog + GroupCatalog + RelationshipKindCatalog
                              + CastPack
                                  ↓
                         ResolvedCastPack
                                  ↓
                   CastRuntime + StoryDirector + GameKernel
~~~

`CharacterDefinition` 持有稳定人格、玩法素质、能力和表演提示；Group 持有长期成员与
基础关系；CastPack 持有本局选择、道具、槽位、剧情和关系状态覆盖。运行时不得从
`visualPackID` 推断人格，也不得把 Group membership 推断为社会关系。

每个玩法插件至少声明：

- id、显示名、groupID、排序和 implementationID；
- 使用的 sceneIDs、actionFamilies、propIDs、关系条件和输入来源；
- 默认开关、所需权限、缺少资源时的降级策略；
- 是否显示在托盘、角色操作环、设置页和诊断入口。

## 3. 角色表现契约

### 3.0 角色档案与当前状态

每个 `EntityKind.character` 必须以角色 ID 关联一份角色档案。档案属于角色，不属于
`visualPackID`；贾宝玉临时复用麻薯猫素材时仍使用贾宝玉的背景、人格和表演方式。

角色档案固定包含五部分。权威源位于
`pet-asset-forge/characters/profiles/*.yml`，由 `uv run forge sync-catalog` 校验并投影到运行时
`desktop/Resources/characters/catalog.json`；运行时文件不是第二份人工事实源。

| 部分 | 内容 | 消费者 |
|---|---|---|
| `background` | 双语经历、长期动机、关系态度和行为边界 | 大脑上下文、角色详情、素材策划 |
| `personality` | social、curiosity、playfulness、diligence、empathy、independence、teasing，0~100 | Goal/Scene 倾向、台词与动作风格 |
| `aptitudes` | mobility、handling、focus、presence、impact，0~100 | 窗口、道具、陪伴、社交和可选战斗玩法 |
| `performance_prompt` | 双语动作导演语言 | 管线 A 中文 key pose、H3 英文动作 prompt |
| `dialogue` | 双语说话风格、自称、偏好/禁用表达、五种 SpeechIntent 的单条 few-shot 与 fallback | 本地 Qwen 一句话表现层、确定性回退 |

五项玩法素质必须直接对应当前玩法：`mobility` 管窗口攀爬、荡窗、位移和闪避；
`handling` 管道具、递物和机甲操作；`focus` 管阅读、编码陪伴和长场景稳定性；
`presence` 管问候、嘲讽、演出和吸引注意；`impact` 管负重、攻击、受击和窗口破坏。
能力包仍是准入门：`impact=100` 不能让没有 combat/destruction 能力的角色自动攻击。

角色档案是长期定义；BrainState 的 energy、socialNeed、boredom、affection、stress
等是当前状态。当前状态可以改变动作选择和强度，但不能覆写稳定人格或玩法素质。
不采用通用 RPG 的力量/敏捷/智力/魅力六维，因为它们不能直接覆盖桌宠主要玩法，
并且会与人格和 BrainState 重复。

### 3.1 普通角色基础动作包

所有可作为普通角色运行的 EntityKind.character 都应以同一套语义动作作为最低共识。
首发包包含 24 个基础动作：

| 组 | 语义动作 |
|---|---|
| 移动与姿态 | idle、walk、run、turn、jump_start、land、sit、stand_up |
| 注意与指向 | look、look_around、point、beckon |
| 情绪与社交表达 | greet、happy、think、complain、tease、surprised、annoyed |
| 对话与反馈 | talk、listen、nod、shake_head |
| 休息 | sleep |

另有 6 个不改变基础契约的公开扩展：airborne、fall、recover、crouch、stretch、
yawn。它们用于扩展节奏、姿态和受击/恢复表现，角色可以分批补齐。

除此之外，每个能够被场景邀请、自动轮换或作为剧情成员加载的角色，必须有两个
生命周期语义：

~~~text
enter_scene    加入场景、被召唤或从场外进入
exit_scene     离开场景、被送走或回到场外
~~~

生命周期动作不是“普通动作菜单”中的两个按钮。它们必须能够根据角色身份和舞台
选择不同的表现模板：

| 角色/场景 | 入场示例 | 出场示例 |
|---|---|---|
| 普通人、房间舞台 | enter_scene → 从房间/门后走出 | exit_scene → 走回房间/关门 |
| 仙人、神话角色 | 腾云驾雾、降落到舞台 | 腾云升空、化云离开 |
| 幽灵/能量体 | 显现、渐显、穿过边界 | 消散、渐隐、穿墙离开 |
| 机甲/驾驶关系 | 启动、展开、进入待机位 | 关机、收拢、离开驾驶位 |

统一语义保证剧情和场景调度不依赖具体文件名；角色专属表现由 entryProfile、
exitProfile、舞台条件和动作候选链决定。没有专属入场或出场素材时可以使用确定性
通用降级，但 Content Verdict 必须保留 fallback。

完整字段、候选链、QA 和素材门禁见 [action-foundation.md](action-foundation.md)。

### 3.2 语义动作与素材覆盖分离

角色动作的状态只有三类：

| 状态 | 含义 | 玩法行为 |
|---|---|---|
| exact | 有符合角色和语义的专属素材 | 可以执行专属表现 |
| fallback | 专属素材缺失，但候选链有可接受通用表现 | 逻辑可完成，必须标记降级 |
| missing | 没有可接受表现 | 跳过该表现或使用声明的几何/文本兜底 |

因此：

- “有 idle 和 walk”只能说明角色有基础降级包；
- Logic PASS 不代表角色有完整的动作素材；
- enter_scene / exit_scene 的 fallback 不得伪装成腾云、显现或其他专属演出；
- 视觉素材入库还要通过 canonical、key pose、抠图、QA、curation、同步和溯源门禁。

## 4. 实体与能力包

普通角色基础包是共同语言，玩法能力则按实体和场景追加。能力包不应该被塞进
每个角色的基础动作清单。

| 能力包 | 典型语义 | 参与实体 | 首选降级 |
|---|---|---|---|
| 窗口 | climb_up、hang_edge、peek_over、window_peek、perch_window | 角色 + 窗口/窗台 | walk + look/point |
| 道具 | take、hold、use、give、receive、drop | 角色 + 道具 + 插槽 | 几何道具、point、台词 |
| 角色社交 | greet_other、comfort、argue、celebrate、follow_other | 角色 + 角色 | greet、listen、talk |
| 机甲/驾驶 | activate、standby、guard、enter_cockpit、exit_cockpit | 角色 + 机甲 + 驾驶舱 | 几何机甲、point、greet |
| 破坏/受击 | hit_react、crack_react、stagger、recover | 目标 + 工具/冲撞者 | 短时特效、surprised、fall |
| 嘲讽/战斗 | taunt、combat_ready、attack、defend、dodge、hit_react、stagger、victory、defeat、retreat | 具备战斗能力的角色 + 目标 | tease、talk、surprised、recover |

能力是否可用由三个条件共同决定：

~~~text
目录声明能力
    ∩ 世界实体与插槽存在
    ∩ 角色对该语义的 exact/fallback 覆盖
~~~

准入顺序固定为 capability gate → 世界/slot 条件 → ActionCatalog 素材解析。
因此素材包偶然含有 attack clip 不会给无 combat 能力的角色授予攻击权限；反过来，
有能力但缺专属 clip 时，只能按该能力族允许的 fallback 降级并记录 Content Verdict。

强接触动作、机甲专属动作和破坏反应不因角色在 CastPack 中出现就自动获得。
缺少专属资源时，世界仍可以保留逻辑参与者和目标，但必须显示明确的降级事实。

### 4.1 窗口停留的角色化执行

窗口玩法使用统一语义 perch_window，而不是把所有角色都直接播放 sit。角色目录
为它声明 windowPerchProfile：

对应素材必须在最终帧保持窗台停留姿态并占用 `window_sill`；`return_to_idle` 只能
作为预览或降级，不能表示已经完成窗口停留。缺少角色化路径时必须标记
`fallback`，不得把通用 `sit` 伪装成 direct/climb/swing/lean 的专属表现。

| profile | 中文 | 动作弧 |
|---|---|---|
| direct_perch | 直接登上 | approach → land/perch → sit |
| climb_perch | 攀爬登上 | approach → climb_up → pull_up → land → sit |
| swing_perch | 荡到窗台 | approach → hang_edge → swing → land → sit |
| lean_window | 倚靠窗口 | approach → lean_sill → look_out |

普通人通常使用 climb_perch，轻小、飞行角色可以 direct_perch，有绳索/尾巴/
翅膀或摆荡能力的角色可以 swing_perch；不适合坐下的角色使用 lean_window。
目标是同一玩法语义，不是同一动作文件。缺少专属路径时才降级到 window_bottom、
floor_near 或 look_out。

### 4.2 嘲讽、战斗与窗口破坏

tease 表达友好或俏皮的调侃；taunt 表达正式挑衅，可以成为战斗前置、敌对关系
升级或争执节拍。具备 combat 能力的角色才可选择 combat_ready、attack、defend、
dodge、hit_react、victory、defeat 和 retreat。战斗必须绑定目标、接触框、可中断
点和恢复路径，默认只影响 MyPet 世界，不伤害真实外部应用。

窗口破坏由世界事件和特效目录共同完成：

~~~text
damage_window / strike_window
    → 校验工具、目标窗口和规则
    → WindowDamageEvent
    → EffectCatalog 选择窗口表面特效
    → hit_react / surprised / stagger
    → TTL 到期或 repair_window 清理
~~~

首批窗口特效包括 window_crack（窗口裂痕 / Window Crack）、
window_bullet_hole（弹孔 / Window Bullet Hole）、window_impact_flash（冲击闪光 /
Window Impact Flash）、window_shards（碎片飞散 / Window Shards）和 window_smoke
（窗口烟雾 / Window Smoke）。特效需要目标锚点、TTL、叠加上限、点击穿透和缺失
降级；它们覆盖的是 MyPet 表现层，不修改真实外部窗口。

## 5. 名称与本地化契约

动作、角色、角色组、剧组成员、道具、窗口玩法、特效和配置项都必须同时提供稳定
英文 ID、中文标签和英文标签。默认菜单显示中文，详情、诊断、导出和语言切换可以
显示“中文 / English”。

统一字段形状：

~~~json
{
  "id": "perch_window",
  "displayName": {
    "zh-Hans": "坐在窗口上",
    "en": "Perch on Window"
  }
}
~~~

中文缺失时显示 English 并报告配置问题，不能直接显示 ID。名称的本地化字段不
参与存档、回放、关系图或动作候选链；角色 YAML、CastPack、PropCatalog、
EffectCatalog 和玩法插件必须使用同一 LocalizedLabel 结构。

角色、道具和配置项的最小形状：

~~~json
{
  "id": "sun_wukong",
  "displayName": {
    "zh-Hans": "孙悟空",
    "en": "Sun Wukong"
  },
  "description": {
    "zh-Hans": "可以使用金箍棒并声明 combat 能力",
    "en": "Can use the staff and declare the combat capability"
  }
}
~~~

PropCatalog、EffectCatalog 和玩法插件使用相同的 displayName/description 结构。
默认菜单、托盘和角色操作环以 zh-Hans 为主；详情、配置检查、素材审计和语言切换
提供 English 对照。显示名不由 Swift 临时翻译，也不允许菜单只显示裸 ID。

## 6. 输入、策略与优先级

输入路由的完整契约见 [gameplay-input-channels.md](gameplay-input-channels.md)。
玩法层只依赖其稳定输出：

~~~text
窗口/鼠标/用户事件 → GameEvent
AX/OCR/聊天/编码/浏览器 → ContentObservation
两者都经策略 → BehaviorRequest / Goal
~~~

三条通道不是三层大脑：

| 通道 | 作用 | 约束 |
|---|---|---|
| 抢占 | 用户直接互动、前台切换和明确窗口变化 | 可立即打断，不等待 LLM 或 OCR |
| 快速反应 | 本地决策脑根据标题、活动和上下文生成短反应 | 只能输出 Goal/QuickReaction |
| 内容 | 异步提供 AX、OCR、聊天、编码、浏览器观察 | 不能直接移动、说话或写世界 |

行为请求的优先级带：

~~~text
P0 用户直接操作
P1 前台/目标窗口变化
P2 内容语义变化
P3 普通轮询与后台重规划
~~~

每个异步结果都带 PlanEpoch、来源和过期时间。旧窗口、旧内容或旧计划的结果
到达时必须丢弃。内容插件关闭、权限不足或 TTL 到期时，基础玩法仍然可运行。

## 7. 短回合与场景配方

短回合是玩家可感知的完整单元，不是单一动作。每个配方至少声明：

- 触发条件和目标实体；
- 需要的角色能力、窗口/道具/关系条件；
- 参与者的 enter_scene / exit_scene 规则；
- 移动、语义动作、台词、等待和可抢占边界；
- 成功、取消、过期和缺资源时的终态；
- 关系效果、剧情事实和短时特效是否提交。

推荐的配方形状：

~~~text
prepare → enter/approach → claim → perform → resolve → release → exit/return
~~~

普通独立反应可以省略 claim 和 exit，但所有会引入新角色、结束剧情或改变
舞台占用的配方必须显式处理入场和出场。

首批配方包括：

- window_climb_and_peek：靠近窗口 → 攀爬/探头 → 观察 → 回到安全位；
- join_coding：入场 → 靠近编码窗口 → look/think → 短台词；
- prop_transfer：双方入场或定位 → take → give/receive → 重新挂接；
- relationship_conflict：面对 → talk/argue → 关系效果 → exit_scene 或恢复；
- mech_launch：机甲入场 → activate → enter_cockpit → 保护/巡逻；
- story_handoff：释放节拍发出递物事件 → 接收节拍匹配 → 表现层短插值。

场景可以被 P0/P1 抢占。抢占不能由表现层直接清空槽位；释放、转交和关系效果
必须在下一个内核事件边界提交。

## 8. 角色操作环与动作入口

角色操作环遵循“直接动作优先”：

- 第一级直接平铺常见动作，如问候、开心、思考、抱怨、招手、睡觉；
- 提供“聊天”和“更多”；
- 不允许放一个名为“动作”的中间按钮再进入动作子菜单；
- 窗口、道具、关系和玩法不是一级分类；
- 低频基础动作和已启用能力包可以进入唯一的“更多”入口；
- enter_scene / exit_scene 由场景生命周期触发，不作为用户按钮。

用户直接点击一个动作时，系统提交单一 BehaviorRequest，不应把它绕成聊天请求
或交给内容插件。复合要求、自然对话和复杂玩法才进入 Goal/Scene 路径。

## 9. 关系、剧情与效果

关系、剧情的领域边界见 [story-and-relationships.md](story-and-relationships.md)：

- RelationshipGraph 表达稳定社会/驾驶/归属关系；
- StoryFacts 表达短期事实；
- SceneGraph 表达空间父子和插槽；
- WorldState 表达当前槽位、资源占用和实体生命周期；
- StoryDirector 只选择满足条件的节拍，不直接播放文件或改关系数值。

动作完成后提交的是声明式效果，例如增加紧张度、记录“刚刚递物”或释放驾驶舱。
大脑不能直接修改关系值；表现层的火花、烟雾、裂痕等只是短时特效，不等于关系
效果或破坏事件。

## 10. 设置与目录投影

设置必须由目录生成，至少有以下玩法组：

~~~text
总览
抢占响应
快速反应
内容通道
窗口与道具
破坏与特效
角色与关系
屏幕剧情
回合与节奏
~~~

“大脑”“感知与权限”“诊断”是独立设置域，不应和玩法插件混为一个实现层。
设置只保存稳定 ID 的启停、参数、白名单和权限状态；不保存显示名、动作文件名
或第二份角色名单。

## 11. 可观察验收

每次新玩法或新角色验收必须同时给出三张结果：

### Logic Verdict

- 事件是否经 EventInbox 和 tick 边界消费；
- 抢占、epoch、资源 claim、槽位和释放是否正确；
- 场景是否能成功、取消、过期并回到安全状态；
- 关系效果和剧情事实是否只由内核提交；
- 没有 LLM、Needle 或专属素材时是否按规则降级。

### Content Verdict

- 普通角色 24 个基础动作、6 个扩展和入/出场的覆盖表；
- 角色声明的每个能力包的 exact/fallback/missing；
- canonical、key pose、透明度、安全框、identity 和 curation 结果；
- petpack 是否同步，文本溯源是否完整；
- 专属表现是否被错误地报告为通用降级。

### Platform Verdict

- 真实 AppKit 场景的入场、移动、出场和叠加观感；
- 真实窗口/AX/OCR/屏幕录制权限及应用矩阵；
- 真实角色包、WebP 解码、帧率、内存和长时间运行；
- 平台失败不能被 Headless Harness 的 Logic PASS 掩盖。

## 12. 当前基线与迁移顺序

截至本规格编写时，仓库中的运行时和素材仍处于迁移中：

1. 当前代码仍以既有 ActionCatalog、基础 idle/walk 包和旧的核心 performance
   列表为实现基线；
2. 24+6 基础动作、enter_scene/exit_scene、能力包覆盖元数据和 Content Verdict
   是新的统一目标，不宣称已经全部完成；
3. 现有角色可以先作为 idle/walk 降级包参与逻辑玩法，但必须在素材审计中明确
   fallback，不能称为动作完整；
4. 迁移顺序应是：先更新语义目录与数据结构，再更新角色 YAML 和覆盖报告，
   然后分批生成/确认素材，最后同步运行时 petpack；
5. 新角色入库前，先确认 canonical 和入/出场首尾帧，再启动需要真实肢体运动的
   视频动作生成。

禁止事项：

- 在菜单、SceneRecipe 或 Swift 中重新复制一套动作名称；
- 用 idle 伪装专属入场、出场、机甲或强接触动作；
- 用渲染层回调修改世界所有权、关系数值或槽位；
- 用一个“素材存在”布尔值掩盖 exact/fallback/missing；
- 把历史测试通过、逻辑降级或几何 fallback 写成视觉资产已完成。
