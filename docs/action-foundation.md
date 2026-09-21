# 动作语义与角色素材契约

> 状态：玩法动作模型重构基线（2026-09-21）。本文是所有玩法文档、角色动作表、素材审计和运行时 `ActionCatalog` 的动作语义来源。它定义“角色能做什么”和“素材如何覆盖语义”；不把每个玩法写成一段不可复用的大动画。
>
> 总玩法规格见 [gameplay-requirements.md](gameplay-requirements.md)；运行时状态与迁移见 [game-v2.md](game-v2.md)；素材事实见 [asset-audit.md](asset-audit.md)。

## 1. 术语与边界

### 1.1 语义动作不是 clip 名

`greet`、`sit`、`give` 是玩法使用的稳定语义动作；`wave`、`sit_idle`、`hand_over` 是某个角色包可能提供的具体 clip。大脑、场景和剧情只选择语义动作，`ActionRuntime` 再按角色能力、目标和素材覆盖解析表现。

```text
Goal / StoryBeat
      ↓
SemanticAction
      ↓
ActionCatalog + capability gate
      ↓
clip candidate chain / pose / prop / geometry fallback
      ↓
SceneProgram → SceneRuntime.tick()
```

### 1.2 普通角色与其他参与者

本文的“普通角色”专指 `EntityKind.character`。它与以下对象分开管理：

- `mech`：有独立根节点、驾驶舱和机甲动作族；
- `prop`：由道具目录和 socket 管理，通常没有主动动作；
- `surface`：窗口、窗台、桌面等可占用空间；
- `effect`：短时视觉特效，不属于角色动作素材。

机甲、特效和道具的素材不得为了凑普通角色动作数量而塞进角色基础包。

### 1.3 三种覆盖结果

每个语义动作都要报告覆盖等级：

| 覆盖 | 含义 | 是否算视觉完成 |
|---|---|---:|
| `exact` | 当前角色有经过 QA 的专属 clip 或明确姿态素材 | 是 |
| `fallback` | 使用候选链、基础姿态、道具表现或确定性几何降级 | 否；只算逻辑完成 |
| `missing` | 没有安全、可观察的表现路径 | 否；需要修复能力或玩法配置 |

`fallback` 可以让回合收束，但不能在素材审计或发布报告中写成 `exact`。

### 1.4 角色表演是动作契约的一部分

语义动作定义“做什么”，角色档案的 `performance_prompt` 定义“这个角色怎样做”。
素材生成统一按以下顺序编译 prompt：

```text
style → visual identity → character performance → action motion → camera/safety/loop constraints
```

管线 A 对动作 key pose 使用中文表演提示词，canonical 母版保持中性身份基准；
管线 B 的每个 H3 动作使用英文表演提示词。背景原文和 0~100 数值不直接堆进生成
prompt，由角色档案先翻译成速度、幅度、节奏、重心、姿态、表情通道、操作习惯和
恢复方式。动作 YAML 只保留当前动作事实及必要的专属细节，不重复整段人格。

同一 `happy` 可以表现为孙悟空的快速得意跃起、林黛玉的掩袖轻笑、沙悟净的缓慢
点头或猪八戒的夸张大笑；它们仍共享同一语义 ID 和候选链。修改角色档案中的
表演提示词会使相关动作计划和素材过期，但只有视觉身份变化才要求重新确认 canonical。

## 2. 普通角色基础动作包

普通角色不再只围绕 `idle / walk / 五个情绪动作` 生产。基础包分成 24 个首发动作和 6 个公共扩展动作；完整普通角色语义目录共 30 个动作。嘲讽的轻量互动由 `tease` 表达，正式挑衅与战斗由条件能力包表达，不把战斗动作强行塞给不具备战斗身份的普通角色。

### 2.1 24 个首发动作

这 24 个动作是普通角色的首发生产和角色操作环的主要能力范围。新角色最终应为它们提供独立、可 QA 的表现；在迁移期间，运行时允许按候选链降级。

| # | 语义 ID | 首选 clip | 类型 | 用途 |
|---:|---|---|---|---|
| 1 | `idle` | `base/idle` | 循环 | 普通待机、回合间稳定姿态 |
| 2 | `walk` | `base/walk` | 循环 | 地面、窗口和角色之间移动 |
| 3 | `run` | `base/run` | 循环 | 紧急靠近、追逐、快速反应 |
| 4 | `turn` | `turn` | 一次 | 改变朝向、面对目标 |
| 5 | `jump_start` | `jump_start` | 一次 | 起跳前置、跳向窗台 |
| 6 | `land` | `land` | 一次 | 落地、窗台着陆收束 |
| 7 | `sit` | `sit` / `sit_idle` | 姿态/循环 | 坐在地面、窗台或座位 |
| 8 | `stand_up` | `stand_up` | 一次 | 从坐、蹲或低姿态恢复站立 |
| 9 | `look` | `look` / `observe` | 一次/循环 | 看向一个目标 |
| 10 | `look_around` | `look_around` | 循环 | 观察周围、寻找窗口或道具 |
| 11 | `point` | `point` | 一次 | 指向窗口、道具或另一个角色 |
| 12 | `beckon` | `beckon` | 一次 | 招手示意靠近、邀请互动 |
| 13 | `greet` | `wave` / `greet_wave` | 一次 | 问候用户或其他角色 |
| 14 | `happy` | `happy` | 一次 | 开心、成功、正向回应 |
| 15 | `think` | `think` | 循环/一次 | 思考、阅读、陪伴用户工作 |
| 16 | `complain` | `complain` | 一次 | 抗议、被打扰、不满 |
| 17 | `tease` | `tease` | 一次 | 俏皮调侃，不是辱骂 |
| 18 | `surprised` | `surprised` / `startle` | 一次 | 新窗口、突然靠近或意外事件 |
| 19 | `annoyed` | `annoyed` | 一次 | 烦躁、被连续打扰 |
| 20 | `talk` | `talk` / `greet_other` | 循环/一次 | 说话时的可观察表现 |
| 21 | `listen` | `listen` / `look_at` | 循环/一次 | 倾听用户或其他角色 |
| 22 | `nod` | `nod` | 一次 | 同意、回应、确认 |
| 23 | `shake_head` | `shake_head` | 一次 | 拒绝、不同意、困惑 |
| 24 | `sleep` | `sleep_loop` / `sleep` | 循环 | 睡觉、低能量、窗口休息 |

`greet`、`sleep` 是语义 ID；素材工厂可以分别使用 `wave`、`sleep_loop` 作为 canonical clip 名。动作名不要求和角色语言、文化身份完全字面一致，但必须让用户能辨认行为含义。

### 2.1.1 基础动作中英文对照

稳定 ID 使用英文 snake_case；配置和 UI 标签必须同时提供中文与英文，默认菜单显示中文。

| ID | 中文默认显示 | English |
|---|---|---|
| `idle` | 待机 | Idle |
| `walk` | 行走 | Walk |
| `run` | 奔跑 | Run |
| `turn` | 转身 | Turn |
| `jump_start` | 起跳 | Jump Start |
| `land` | 落地 | Land |
| `sit` | 坐下 | Sit |
| `stand_up` | 起身 | Stand Up |
| `look` | 注视 | Look |
| `look_around` | 环顾 | Look Around |
| `point` | 指向 | Point |
| `beckon` | 招手 | Beckon |
| `greet` | 问候 | Greet |
| `happy` | 开心 | Happy |
| `think` | 思考 | Think |
| `complain` | 抱怨 | Complain |
| `tease` | 调侃 | Tease |
| `surprised` | 惊讶 | Surprised |
| `annoyed` | 烦躁 | Annoyed |
| `talk` | 说话 | Talk |
| `listen` | 倾听 | Listen |
| `nod` | 点头 | Nod |
| `shake_head` | 摇头 | Shake Head |
| `sleep` | 睡觉 | Sleep |

正式挑衅单独使用 `taunt`（嘲讽 / Taunt），避免把友好的 `tease` 与战斗场景中的挑衅混为一谈。

### 2.2 6 个公共扩展动作

以下动作仍属于普通角色，不属于窗口、道具或机甲专属能力；它们可以在首发 24 个动作之后作为第二批公共素材：

```text
airborne    # 空中状态
fall        # 跌落或被抛起后的下落
recover     # 跌倒、受击或失衡后的恢复
crouch      # 蹲伏、贴近窗口底沿或躲避
stretch     # 伸懒腰、长时间工作后的舒展
yawn        # 困倦、休息前后的短表现
```

`airborne / fall / recover` 也服务于拖拽、投掷和受击状态；没有独立 clip 时必须使用安全的状态姿态，不得让角色卡在半空或把不完整的中间帧当成最终状态。

| ID | 中文默认显示 | English |
|---|---|---|
| `airborne` | 空中 | Airborne |
| `fall` | 跌落 | Fall |
| `recover` | 恢复 | Recover |
| `crouch` | 蹲伏 | Crouch |
| `stretch` | 伸展 | Stretch |
| `yawn` | 打哈欠 | Yawn |

### 2.3 基础动作的组合关系

普通动作不是孤立按钮，而是可被场景组合的基础词汇：

```text
move_to(window)
→ turn
→ look
→ point / beckon
→ talk / listen
→ happy / complain / tease
```

```text
spawn(book)
→ take / hold
→ sit
→ think
→ read      # read 是道具能力动作；没有时以 think + socket 降级
```

```text
鼠标突然靠近
→ surprised
→ airborne 或 retreat
→ recover
```

### 2.4 基础动作候选链

候选从左到右解析，第一项存在且通过能力门控的表现获选。下面是跨角色的默认候选，不限制角色增加更贴切的专属动作：

| 语义动作 | 默认候选 |
|---|---|
| `greet` | `greet_wave → wave → happy → nod` |
| `happy` | `happy → celebrate → jump → wave → nod` |
| `think` | `think → read → sit_idle → nod → look` |
| `complain` | `complain → annoyed → shake_head → think → nod` |
| `tease` | `tease → taunt → mock_turn → flirt → tail_wag → happy → wave` |
| `surprised` | `surprised → startle → jump → look_around → look` |
| `annoyed` | `annoyed → complain → shake_head → think` |
| `talk` | `talk → greet_other → greet_wave → nod` |
| `listen` | `listen → look_at → think → nod` |
| `sleep` | `sleep_loop → sleep → doze → yawn → sit_idle → idle` |
| `run` | `run → walk` |
| `turn` | `turn → look → walk` |
| `sit` | `sit → sit_idle → perch → think` |

候选链保证逻辑回合完成，不保证视觉语义等价。`Content Verdict` 必须记录实际选中的是 `exact` 还是 `fallback`。

## 3. 能力动作包

动作族不是“所有角色必须拥有的 clip 清单”，而是角色声明能力后可被玩法引用的语义集合。角色资料必须声明身体能力、支撑面、操作点和允许的降级路径。

### 3.1 窗口能力

```text
jump_to_sill / climb_up / climb_down / pull_up
hang_edge / peek_over / sit_sill / lean_sill
look_out / drop_from_sill
```

高质量窗口玩法首批优先覆盖 `climb_up / hang_edge / peek_over`；最大化窗口、顶部空间不足或角色身体过宽时，动作必须切换为 `titlebar_perch / hang_edge / peek_over / lean_side / window_bottom / floor_near` 等可见姿态。

#### 窗口停留不是单一的 sit clip

窗口互动的统一语义是 `perch_window`（在窗口/窗台上停留），结果必须占用
`window_sill` 或等价 slot；`sit` 只是最后的身体姿态。角色资料声明
`windowPerchProfile`，至少支持以下路线：

`perch_window` 的专属 clip 必须以窗台停留姿态结束并保持（通常使用
`type: once` + `loop.mode: open`）；不能用“登上后立刻回到 idle”的短动作冒充
已经占用窗台。缺少专属 clip 时，运行时只能记录为 fallback，并使用安全的
`window_bottom`、`floor_near` 或 `look_out` 路径。

| profile | 中文 | 适用角色 | 动作弧 |
|---|---|---|---|
| `direct_perch` | 直接登上 | 轻小、飞行或已有窗口高度的角色 | approach → land/perch → sit |
| `climb_perch` | 攀爬登上 | 普通人、需要真实高度变化的角色 | approach → climb_up → pull_up → land → sit |
| `swing_perch` | 荡到窗台 | 有绳索、尾巴、翅膀或摆荡能力的角色 | approach → hang_edge → swing → land → sit |
| `lean_window` | 倚靠窗口 | 不适合坐下或窗口没有安全坐面 | approach → lean_sill → look_out |

同一个 `perch_window` 可以由不同角色采用不同 profile；缺少专属路径时才
降级为 `window_bottom`、`floor_near` 或 `look_out`。不能让所有
角色都直接播放 `sit` 来伪装已经完成窗口互动。

### 3.2 道具能力

```text
reach / take / hold / carry / inspect
read / type / drink / eat / use / play
place / push / pull / throw / give / receive
```

`take / hold / carry / place` 是通用道具交互；`read / type / drink / eat / play` 由具体道具和场景声明；`give / receive` 需要两个参与者、明确目标和 slot/attachment 生命周期。

简单拿取、持有、阅读和放置可以由姿态、道具图、socket 和场景节拍组成。递物、接物、争抢等强接触动作需要专属 clip 或明确的 hand-to-hand 几何表现。

### 3.3 社交能力

```text
face_other / look_at / approach_other / follow
greet_other / high_five / touch / comfort
tease_other / argue / play_together / hug / protect
```

普通角色基础包已经包含 `talk / listen / greet / nod / shake_head`；上述动作表达目标关系、距离和接触，不重复生产同一语义的孤立表演。`comfort / hug / high_five` 等强接触动作必须在参与者对齐、可中断和失败清理上有明确契约。

### 3.4 机甲与驾驶能力

机甲是独立实体：

```text
standby / activate / deactivate / signal / move
guard / damage / respond
```

驾驶员与机甲之间的联合动作是：

```text
enter_cockpit / exit_cockpit
```

它们需要 `front / cockpit / hand / shoulder` 等锚点，不能把机甲动作当作普通角色动作，也不能把机甲当作普通手持道具。

### 3.5 破坏与受击

破坏发起动作：

```text
aim / use_tool / shoot / strike / throw_tool / explode
```

受击反应：

```text
hit_react / stagger / knockback / damage_react / recover
```

枪、锤子、炸弹属于工具道具；射击、砸击、爆炸属于世界事件；弹孔、裂痕、火花、烟雾和受击标记属于独立 `EffectCatalog` 资源。它们不计入普通角色 24 个基础动作。

### 3.6 嘲讽与战斗能力

轻量的 `tease` 是普通角色基础动作；正式挑衅和战斗需要角色或剧组声明
`combat` 能力包：

~~~text
taunt           正式嘲讽 / Taunt
combat_ready    战斗准备 / Combat Ready
attack          攻击 / Attack
defend          防御 / Defend
dodge           闪避 / Dodge
hit_react       受击 / Hit React
stagger         踉跄 / Stagger
victory         胜利 / Victory
defeat          失败 / Defeat
retreat         撤退 / Retreat
~~~

`taunt` 可以作为战斗前置、争执升级或敌对关系表达；`attack`、`defend`、
`dodge` 和 `hit_react` 必须绑定目标、碰撞/接触框、可中断点和安全终态。
战斗先定义为可回放、可恢复的屏幕表现，不默认伤害真实应用或删除角色。

### 3.7 窗口破坏与短时特效

窗口破坏是“世界事件 + 特效资源”的组合，不是一个角色动作：

~~~text
damage_window / strike_window
    → GameKernel 校验工具、目标窗口和规则
    → commit WindowDamageEvent
    → EffectCatalog 选择窗口表面特效
    → hit_react / surprised / stagger
    → TTL 到期或 repair_window 清理
~~~

首批特效 ID：

| ID | 中文 | English | 类型 |
|---|---|---|---|
| `window_crack` | 窗口裂痕 | Window Crack | 贴面、可叠加、TTL |
| `window_bullet_hole` | 弹孔 | Window Bullet Hole | 贴面、上限、TTL |
| `window_impact_flash` | 冲击闪光 | Window Impact Flash | 一次性 |
| `window_shards` | 碎片飞散 | Window Shards | 一次性、粒子补充 |
| `window_smoke` | 窗口烟雾 | Window Smoke | 循环、TTL |

特效目录必须声明目标锚点、持续时间、叠加上限、点击穿透和缺失降级。它们只覆盖
MyPet 的窗口表现层，不修改外部窗口内容；弹孔、裂痕等有明确语义的效果必须有
独立素材，火花、烟雾、拖尾和能量束才允许用粒子/程序化效果补充。

## 4. 名称与本地化契约

动作、角色、角色组、剧组成员、道具、窗口玩法、特效和配置项都必须同时提供
稳定英文 ID、中文标签和英文标签。稳定 ID 用于代码、存档、日志、回放和资源
路径；显示名不允许反过来当主键。

推荐配置形状：

~~~json
{
  "id": "perch_window",
  "displayName": {
    "zh-Hans": "坐在窗口上",
    "en": "Perch on Window"
  },
  "description": {
    "zh-Hans": "根据角色能力选择直接登上、攀爬或荡到窗台",
    "en": "Choose direct, climb, or swing access based on the character"
  }
}
~~~

规则固定为：

- 默认菜单、托盘、角色操作环和设置页显示 zh-Hans 中文；
- English 标签必须同时存在，可用于语言切换、详情、诊断、导出和开发工具；
- 需要双语对照的动作、角色、道具和特效详情显示为“中文 / English”；
- 中文缺失时不得静默显示 ID，必须显示 English 并在诊断中报告缺失；
- 所有资源目录、CastPack、PropCatalog、EffectCatalog 和玩法插件都使用同一
  LocalizedLabel 结构；
- 本地化字段不改变语义 ID、动作候选链、关系图、回放和存档。

### 4.1 角色与道具名称

角色 YAML 和运行时 JSON 至少声明：

~~~yaml
id: sun_wukong
displayName:
  zh-Hans: 孙悟空
  en: Sun Wukong
~~~

道具、窗口玩法和特效使用同样结构。作品角色的中文名和英文转写必须在资源层
确认，不能由菜单临时翻译；同名角色必须使用稳定 ID 区分。

## 5. 动作条目契约

每个语义动作条目必须回答以下问题：

1. 目标类型是世界、窗口、道具、角色还是机甲；
2. 是否需要支撑面、对齐方式、接触点或 socket；
3. 是姿态、循环、位移弧线、一次性动作还是多参与者节拍；
4. 是否允许被 P0/P1/P2 抢占，如何结束、失败和恢复；
5. 是否提交 `effectsOnSuccess`；
6. exact、fallback、missing 如何报告；
7. 素材缺失时使用哪一级安全降级，不得让剧情节拍卡死。

角色能力使用角色无关的声明，例如 `manipulator`、脚、嘴、头、座位和 `can_climb`，不把共享玩法写死为“手”或“前爪”。

## 6. 动作与运行时的责任边界

```text
GoalBrain        决定高层目标
StoryDirector    决定多角色剧情节拍
NeedleBrain      选择合法的下一步语义动作
ActionRuntime    解析目标、能力、claims 和素材覆盖
SceneRuntime     按 tick 执行动作程序
GameKernel       提交世界状态、slot、关系效果和结束原因
Renderer         只消费投影，不写世界真相
```

动作资源 claim 与窗口、座位、道具使用位、驾驶舱等 `InteractionSlot` claim 分开管理；取消、超时、目标失效和抢占时必须同时清理各自的 claim。

动作或剧情只有在程序明确成功后才能提交声明式效果。动作被打断时不提交未完成的关系变化、所有权转移或破坏效果。

## 7. 素材生产分层

普通角色动作生产按以下顺序执行：

```text
canonical / key pose 确认
→ 24 个首发基础动作
→ 6 个公共扩展动作
→ 角色签名动作
→ 窗口 / 道具 / 社交能力包
→ 机甲或特效独立批次
```

`canonical`、`key pose`、动作首尾帧、curation、QA 和同步入包是生产门禁，不是动作语义本身。没有用户确认的静态母版，不启动 H3 动作批次；中间产物也不冒充运行时素材。

## 8. 验收矩阵

每个普通角色的素材审计至少报告：

| 维度 | 必须观察 |
|---|---|
| 身体 | 24 个首发动作的 exact/fallback/missing |
| 公共扩展 | 6 个动作的覆盖和状态安全性 |
| 窗口 | 声明的窗口能力与最大化窗口可见性 |
| 道具 | 操作点、socket、持有/放置和回收 |
| 社交 | 目标对齐、接触框、可中断和关系效果 |
| 机甲 | 机甲实体与驾驶员动作分离 |
| 追溯 | prompt、seed、graph hash、QA 和 curation 记录 |

逻辑 PASS 不等于素材 COMPLETE。缺专属 clip 可以让玩法逻辑通过，但必须在 Content Verdict 和资产审计中保留缺口。

## 9. 与当前代码的迁移关系

当前运行时已经有语义解析、候选回退、窗口安全布局、多角色占位分离和 `exact/fallback/missing` 的 headless 报告；但代码中的 `ActionCatalog` 仍以旧的身体、窗口、道具、社交和机甲枚举为主，普通角色 24/30 动作目录尚未全部接入。

本文件更新后，后续实现顺序是：

1. 将 24 个首发动作加入稳定 `ActionCatalog` 和角色能力投影；
2. 为操作环生成能力过滤后的直接动作入口；
3. 将素材工厂动作 YAML 与语义 ID 对齐；
4. 更新 `Content Verdict`，区分基础动作 exact 与玩法动作 fallback；
5. 再逐角色生成、逐张确认并同步入包。
