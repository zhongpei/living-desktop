# 传统团队格斗设计提案

> 状态：第一版玩法契约已实现；数值仍由确定性模拟器迭代，最终美术仍须逐张审批。
>
> 本文定义 Living Desktop 的传统团队格斗产品方向、首批角色、动作与数值生产流程、
> 共享玩法能量、换人、同伴、连段、受身、HUD、Gameplay CPU、模拟器平衡门和美术资源契约。底层时序、碰撞、输入与回放仍以
> [统一 2D 格斗运行时](unified-2d-combat-runtime.md) 为准；CPU 实现以
> [Classic Combat CPU implementation](gameplay-cpu-implementation.md) 为准。

## 1. 产品方向

目标是传统街机格斗的完整核心，而不是复刻某一款商业游戏：

- 有清晰的立回、距离、攻防、投技、对空、飞行道具、确反、击倒和起身；
- 角色以不对称的获胜方式形成对局，而不是换皮使用相同招式；
- 招式启动、有效段和收招可读，强收益必须对应风险和反制入口；
- CPU 和玩家遵守同一输入、招式识别、身体、碰撞和资源规则；
- 自由换人和同伴召唤是 Living Desktop 的核心差异点，但不绕过中立、硬直和碰撞规则；
- 第一版支持超级技、爆气、防御爆发、方向受身和长连段，但只使用一个统一 PowerGauge，
  不为每种能力增加独立资源槽或隐藏例外。

第一版不宣称达到成熟商业格斗游戏经过多年迭代后的内容量和平衡水平。完成标准是：
两个角色已形成可辨识的完整团队对局，换人和同伴召唤提供额外决策轴，所有结果可由确定性模拟器
复现，并且人类能够从画面理解风险与结果。

## 2. 第一版系统边界

### 2.1 保留的传统格斗核心

- 前进、后退、蹲伏、跳跃、转向；
- 站立防御、下段防御、防御硬直；
- 六个可映射攻击槽、投技、两个角色特殊技；
- 轻重受击、击退、浮空、击倒、倒地和起身；
- 对空、下段、投与防的基本克制；
- 飞行道具的生成、移动、命中、防御、互消和消散；
- 回合时间、胜负、双败和确定性平局规则；
- 每队一名 active fighter 加一名可自由换入、也可作为 assist 召唤的 bench fighter；
- 统一三格 PowerGauge、超级技、攻击爆气和防御爆发；
- 数据驱动的取消、长连段修正、浮空预算、反弹限制和方向受身；
- 默认旁观的中立 NPC，以及误伤后确定性加入战斗的仇恨与升级规则；
- CombatSession 期间跟随角色的 HP、Power 和队伍状态 HUD。

### 2.2 第一版的复杂度约束

- 不让远程、超级技、爆气、爆发和换人分别拥有独立资源槽；
- 不做三人队伍、空中换人或三人长连携；
- 不做角色专属的隐藏受身规则和多套不可见起身无敌例外；
- 不做只有查表或逐帧训练才能理解的隐藏取消窗口；
- 因角色名字而写死的运行时代码。

后续机制必须先证明它补充了新的决策，而不是仅增加输入和记忆负担。

## 3. 权威模块与数据流

```text
Physical Key / Remapped Key        Gameplay CPU
              │                 ActivityArbiter → Planner
              │                         │
              └──────────┬──────────────┘
                         ▼
        LogicalControl / GameplayIntent
                         │
             ┌───────────┴───────────┐
             ▼                       ▼
       FighterInputFrame       PlatformAction
             │                       │
 InputBuffer → CommandMatcher   Capability Policy
             │                       │
             └───────────┬───────────┘
                         ▼
 CombatSession / TeamCombat / Escalation / Resource / Combo
                         │
                         ▼
           ActionTimeline + BodyWorld
                         │
                         ▼
          CombatEvent → RenderSnapshot
```

键盘不能直接绑定角色招式。配置分为三层：

1. 物理键映射到逻辑控制，例如 `keyboard.z -> attack1`；
2. 角色配置把逻辑控制或方向序列映射到稳定 `moveID`；
3. `CommandMatcher` 在合法状态下匹配招式。

玩家重映射键位只改变第一层；更换角色只改变第二层。CPU 的战斗动作产生逻辑输入帧并经过
同一个 InputBuffer 和 CommandMatcher，禁止直接调用 `startMove`。探索、跨窗、拉窗等非战斗
行为输出 `GameplayIntent`，经 capability/policy validation 转换成 PlatformAction；CPU 不直接调用
AX、窗口 Adapter 或 renderer。

生产菜单的“游戏功能设置 → 键盘控制”编辑第一层，而不是把物理键写入角色 profile。它提供
默认方案和角色级覆盖；重复逻辑键以交换方式保持一对一；控制窗口仍有按键按下时，新方案只进入
pending，直到所有物理键释放或窗口失焦并发出全键抬起后才原子切换。旧的独立键位文件只允许
一次性合并到统一 Settings，迁移后删除旧存储键，禁止继续形成第二个配置权威。

## 4. 首批完整对局角色

### 4.1 林黛玉：花瓣诗术

定位：中远距离牵制、防反和空间控制。

获胜方式：用单枚花瓣和中距离攻击约束路线，诱导对手冒险接近，再以防反或击倒重新建立
距离。代价是生命较低、近身脱身能力有限、远程攻击具有明确启动和收招。

| 槽位 | moveID | 用途 | 第一轮候选 |
|---|---|---|---|
| attack1 | `petal_touch` | 近身快速打断 | startup 4，damage 28 |
| attack2 | `sleeve_arc` | 中距离牵制 | startup 6，damage 42 |
| attack3 | `poetry_seal` | 慢速确反重击 | startup 11，damage 78 |
| attack4 | `low_petal_sweep` | 下段检查 | startup 7，damage 38 |
| attack5 | `returning_bloom` | 窄窗口防反 | 输给投、等待和窗口外攻击 |
| attack6 | `falling_petals` | 单枚前向花瓣 | startup 10，damage 44，同屏一枚 |
| throw | `sleeve_redirect` | 反制持续防守 | 短距离，非暴力摔砸表现 |
| special1 | `bury_flower_bloom` | 慢启动范围爆发 | 高收益、高收招 |
| special2 | `petal_refrain` | 多段空间控制 | 严格 rehit/dedupe，可确反 |

`returning_bloom` 必须是规则层防反窗口，不得只是名称为防反的快速攻击。花瓣是独立 projectile
body；动画回调不负责生成命中。

### 4.2 武松：近身压迫

定位：近身压迫、突进、对空和打投。

获胜方式：承担接近风险后持续施加短距离攻击与投技选择。代价是手短、远程能力弱，穿越
飞行道具的窗口短，突进被防后可以被惩罚。

| 槽位 | 工作名 | 用途 | 数值约束 |
|---|---|---|---|
| attack1 | `staff_tip_jab` | 最快近身打断 | 低伤害、低击退 |
| attack2 | `staff_cross_sweep` | 中距离压制 | 明确横扫和收势 |
| attack3 | `staff_upper_lift` | 高伤对空/确反 | 大收招，落空危险 |
| attack4 | `low_kick` | 下段攻击 | 距离短于林黛玉下段 |
| attack5 | `elbow_check` | 近身打断 | 不兼任万能防反 |
| attack6 | `staff_butt_slam` | 中近距离重击 | 被防可罚 |
| throw | `shoulder_turn` | 打投核心 | 近距离，不形成无限循环 |
| special1 | `drunken_feint` | 让身后短反击 | 只在此招使用醉步语言 |
| special2 | `tiger_call` | 慢启动高收益同伴攻击 | 虎为独立视觉实体，不能同时无敌、高伤和安全 |

工作名和具体动作不是原著事实声明。视觉契约阶段必须分别标记原著依据、传统武术借鉴与项目
改编；没有证据的影视造型不得成为默认角色设定。

两名角色的权威候选数值分别位于私有内容仓库的
`characters/lin_daiyu/combat/profile.yml` 与 `characters/wu_song/combat/profile.yml`。两者均保持
`realCombatReady: false`，直到动作、特效、box/hash、真实 AppKit 和人工视觉门全部通过。

## 4.3 当前代码完成面

- `GameplayEnergyState` 是唯一资源，能量消耗在动作开始前原子检查；命中、防御和受击使用同一批次结算；
- `TeamCombatState` 实现 active/bench、共享助战/换人占用和冷却，bench 不参与物理、碰撞或受击；
- 爆气持续 480 logic frames，并只提供 10% 伤害增益；超级技与防御爆发都支付同一 300 上限资源；
- `ComboState` 实现逐击伤害/硬直修正、重复招式惩罚、浮空预算和恢复清理；
- 中立 NPC 默认不在 CombatSession，误伤后下一帧加入并只把首要攻击者当作目标；
- 战斗 HUD 由只读 `BodyPose -> RenderSnapshot` 投影 HP/能量，renderer 不写回规则状态；
- Q/W/E/R 只是默认物理键，依次映射到逻辑 `tag/assist/powerUp/defensiveBurst`；角色 profile 再把逻辑控制映射到动作，CPU 同样只能输出逻辑输入；
- 拉窗/破坏表现经过 `WindowInteractionPolicy` 的全局开关、用户活跃、前台保护、冷却、频率和能量联合授权。

## 5. 每个招式的设计记录

任何招式进入 schema v2 前，必须完成 Move Intent Record：

```yaml
moveID: falling_petals
family: projectile
purpose: mid-range route denial
rangeBand: mid_far
beats: [slow_advance, whiffed_heavy]
losesTo: [close_pressure, narrow_projectile_invuln, preemptive_jump]
startupTell: handkerchief draw and sleeve lift
onHitReward: knockback_and_spacing
onBlockRisk: opponent_gains_ground
onWhiffRisk: punishable_recovery
cancelPolicy: none
energyCost: 45
spectacleTags: [projectile, route_denial]
characterAnimation: lin_daiyu/falling_petals_cast
detachedEffects:
  - effect/petal_spawn
  - projectile/petal_loop
  - effect/petal_hit
  - effect/petal_guard
  - effect/petal_expire
```

设计顺序固定为：用途与反制关系 → 逻辑时序 → box 与运动 → 初始数值 → 合成资源验证 →
模拟调参 → 冻结 gameplay contract → 最终美术。不得先按一段漂亮动画反推碰撞和规则。

## 6. 数值设计方法

### 6.1 统一单位

- 逻辑固定 60 Hz；所有时间以 logic frame 存储；
- 距离、速度和 box 使用 MyPet2D 世界单位；
- 伤害、硬直、击退和资源消耗均为整数；
- 渲染采样率不得改变任何 gameplay 数值。

### 6.2 强度预算

一个招式的强度由多个维度共同构成：启动、覆盖距离、有效段、伤害、命中收益、防御收益、
收招、位移、无敌、护甲和取消能力。增强一个维度时，必须明确由哪个风险维度支付。

以下组合第一版禁止出现：

- 快启动 + 长距离 + 高伤害 + 被防安全；
- 飞行道具快速生成 + 快速恢复 + 同屏无限存在；
- 突进穿弹 + 对打无敌 + 被防安全；
- 防反覆盖打击和投技且失败后不可惩罚；
- 同伴召唤可在受击硬直中无条件发动并立即反转局面。

### 6.3 调参纪律

每轮只调整一种主要变量，例如 startup、recovery、damage、range、projectile speed 或 cooldown。
变更必须记录原因、前后值、场景、种子和指标差异。正式美术不参与数值平衡；数值冻结后，
美术只能提高可读性，不能偷偷延长攻击端点或缩短视觉收招。

## 7. 统一 GameplayEnergy / PowerGauge

### 7.1 一个资源，多种选择

每名角色只有一个权威 `GameplayEnergyState`；进入 CombatSession 后把它显示为上限 300、分为
三格的 `PowerGauge`。资源不在进入战斗时凭空创建或重置，它同时支付战斗、特殊移动和桌面互动，
从而产生“放超级技还是改变地形”的真实取舍。

```text
GameplayEnergyState
  current
  maximum
  regenPerFrame
  regenDelayFrames
  lastSpendFrame
```

第一轮候选成本按 300 上限归一化：

| 行为 | 第一轮候选消耗 |
|---|---:|
| 普通移动、轻攻击 | 0 |
| 重攻击 | 15–24 |
| Dash | 15 |
| 基础远程攻击 | 45 |
| 大跳窗 | 24 |
| 危险跨窗 | 36 |
| 拉动窗口 | 180，并要求消费后至少保留 60 |
| 窗口破坏表现 | 120，并要求消费后至少保留 60 |
| 强化招式 | 100 |
| 攻击爆气 | 200 |
| 超级技 | 300 |
| 防御爆发 | 300，且每回合至多一次 |

具体数值必须经过模拟器调整。所有消耗在招式或系统动作开始时原子扣除；动作因资源不足不得
进入 startup。取消或被打断默认不退款，只有显式的引擎故障回滚可以恢复资源。

拉动窗口和窗口破坏表现属于高干扰动作，不能因为 `current >= cost` 就执行。除能量成本外还要
同时通过全局安全策略、前台工作状态、频率限制和用户授权；能量只是约束之一，不是移动外部窗口
的授权凭证。

### 7.2 获得与反滚雪球

- 普通攻击命中时攻击方获得主要能量；
- 攻击被防时攻击方只获得少量能量；
- 受到伤害时防守方也获得一定能量，避免领先方单向滚雪球；
- 主动接近和近距离交战可以获得极少量能量；
- 长距离后退、空挥和连续发射飞行道具不能净赚能量；
- 不采用足以支持无限龟缩的快速被动恢复。

被动恢复由 `regenPerFrame` 和 `regenDelayFrames` 表达；战斗规则可以在持续后退、己方 projectile
仍存活或刚消费远程动作时增加恢复延迟。具体恢复策略属于 ruleset，不在 CPU 中偷偷加能量。

招式内容分别声明 start cost、on-hit gain、on-guard gain 和 defender gain，参考 FightingICE 的
资源模型，但使用 MyPet 自己的 schema 和确定性结算。相同帧的伤害与能量变化进入同一个
batch，遍历顺序不能改变结果。

### 7.3 保留价值

CPU 不能只检查 `current >= cost`。`ResourcePolicy` 还定义：

```text
energyReserve
energyRiskTolerance
regenPreference
expensiveActionThreshold
```

资源越接近保留线，同一成本的 utility penalty 越高。满能量时鼓励有效消费，低能量时倾向普通
攻击、防守、移动、探索或休息。这样 Energy 形成“积累 → 爆发 → 周旋 → 再积累”的节奏，而不是
一满足最低成本就立即消费。

### 7.4 高级消费

- `super`：高消耗终结技，仍有 startup、box、受击与确反规则；
- `power_up`：短时间增加取消自由度或改变少量招式属性，不简单叠加大幅伤害；
- `defensive_burst`：只能在规定 hitstun 窗口使用，可被预判、防御或诱骗，不能无条件免责；
- 三者竞争同一 PowerGauge，玩家不能在同一笔资源上同时获得全部收益。

### 7.5 窗口互动的全局可调参数

窗口互动采用全局配置，角色 profile 只能在全局限制内表达倾向，不能自行绕过：

```text
WindowInteractionPolicy
  enabled
  pullEnabled
  damageOverlayEnabled
  energyCostScale
  minimumEnergyAfterAction
  pullCooldownFrames
  damageCooldownFrames
  maxActionsPerMinute
  suppressWhileUserActive
  protectForegroundWindow
```

第一轮安全默认值：

| 参数 | 默认值 |
|---|---:|
| `enabled` | true |
| `pullEnabled` | false，用户显式开启后才允许 |
| `damageOverlayEnabled` | true，只产生 MyPet overlay |
| `energyCostScale` | 1.0，全局统一调整 |
| `minimumEnergyAfterAction` | 60 |
| `pullCooldownFrames` | 1800（30 秒） |
| `damageCooldownFrames` | 900（15 秒） |
| `maxActionsPerMinute` | 2 |
| `suppressWhileUserActive` | true |
| `protectForegroundWindow` | true |

`energyCostScale` 同时缩放所有自动窗口拉动和破坏表现成本，设置页可以全局提高或降低；最终成本
仍不得低于 ruleset 的安全下限。`suppressWhileUserActive` 在近期键盘、鼠标、拖拽或编辑活动期间
拒绝自动窗口动作；`protectForegroundWindow` 禁止 CPU 拉动当前工作窗口。窗口拉动需要既有权限
和独立显式开关，窗口破坏始终只是 overlay，不得改变外部应用数据或真实窗口内容。

## 8. 团队、自由换人和同伴召唤

### 8.1 队伍模型

每队包含一名 active fighter 和一名 bench fighter。bench fighter 既可以通过 `tag` 成为新的
active fighter，也可以通过 `assist` 暂时入场执行一次动作。同一名 bench fighter 不能同时处于
standby、assist 和 tag-in 多种状态。

自由换人不是瞬时替换：

1. `TeamCombatSystem` 检查当前状态、冷却、同伴存活状态和安全生成位置；
2. 当前角色进入可被攻击的 `tag_out`；
3. bench fighter 执行 `tag_in` 并进入 BodyWorld；
4. 控制权只在配置的 handoff frame 转移一次；
5. 原 active fighter 进入 standby 并保留 HP、Power 和状态；
6. 队伍进入公共 tag cooldown。

普通换人在 hitstun、blockstun、downed、throw-capture 和 session end 中不可用。受击中只能使用
消耗整槽 Power 的防御爆发或防御换人。换入角色不得在生成第一帧立即执行无敌攻击，退场角色
不得继续保留 PushBox。

### 8.2 Assist 流程

按下逻辑控制 `assist` 后：

1. `AssistSystem` 检查召唤者状态、冷却、同伴状态和安全生成位置；
2. 产生固定的 `AssistCommand`；
3. 同伴作为 CombatSession 参与实体进入 BodyWorld；
4. 完成一个预先声明的 assist move；
5. 进入撤离动作并离开可命中区域；
6. 冷却结束后才能再次召唤。

第一版只允许每名角色声明一个 assist move。assist 与 tag 共用 bench 占用状态和公共冷却，
防止连续召唤后立即无风险换人。

### 8.3 规则约束

- 召唤不能绕过 InputBuffer、ActionTimeline、BodyWorld 或 hit dedupe；
- 召唤者处于 hitstun、downed、throw-capture 或 session end 时不能召唤；
- 同伴具有 HurtBox，可以受击；受击会提前结束动作并延长冷却；
- 同伴默认不具有投技，不触发 KO 胜负，也不能无限阻挡 PushBox；
- 同一队同一时间只有一个同伴实例；
- 同伴攻击遵守 team mask，不命中召唤者；
- 同伴与飞行道具必须进入统一同帧 batch resolution；
- 回放保存 assist command、spawn frame、实体 ID、命中和撤离结果；
- 回放同时保存 tag request、handoff frame、active/bench 交换和公共冷却；
- Tag/Assist 都必须经由逻辑控制映射，键盘不能直接调用 TeamCombatSystem。

### 8.4 首批候选同伴功能

为避免同时制作四个完整角色，第一阶段使用双方的对手作为功能性同伴原型：

- 林黛玉 assist：一枚受限花瓣，提供短暂路线封锁；
- 武松 assist：短距离前进打击，提供有限压制。

这只是规则验证方式。最终角色组合和人物关系必须在内容设计中独立确认，不能因为测试方便就
宣称某两名文学角色组成固定队伍。

## 9. 中立 NPC、误伤与动态参战

### 9.1 默认状态

桌面同时存在多个角色时，未被 CombatSession 编入队伍的角色默认为 `uninvolved`。他们继续执行
观察、探索、交谈或避让等普通 Gameplay CPU 活动：

- 战斗 CPU 不把他们加入合法目标集合；
- 他们不获得队伍、Assist、Tag 或正式回合胜负资格；
- 普通 Story `attack` 仍是 presentation，不会触发误伤；
- 在允许 collateral damage 的桌面混战 ruleset 中，他们保留 HurtBox，因此真实 Combat hit、
  projectile 或带明确 owner 的战斗性环境效果可能误伤他们。

参与状态使用稳定枚举，而不是由“最近是否播放攻击动画”推断：

```text
CombatParticipation
  uninvolved
  alerted(offenderID)
  incidentalCombatant(primaryOffenderID)
  withdrawing
  rosterParticipant(teamID)
```

### 9.2 误伤归属与参战流程

任何造成至少 1 点真实伤害的命中都由 CombatEvent 携带 `sourceActorID`、`sourceTeamID` 和
`sourceEntityID`；projectile、assist 与环境效果必须追溯到最终责任角色。引擎不猜攻击者是否
“故意”，伤害归属者承担误伤责任。

默认 `joinOnFirstDamagingHit = true`：

1. 当前帧仍按统一 collision batch 完成伤害，不在遍历中途改变 target mask；
2. `AggroLedger` 为受害 NPC 记录伤害来源、数值、帧和责任队伍；
3. NPC 进入短暂 `alerted`，中断普通 activity commitment；
4. `CombatEscalationSystem` 在下一逻辑帧检查能力、ruleset 和人数上限；
5. 合法时把 NPC 作为 `incidentalCombatant` 加入当前 CombatSession；
6. Gameplay CPU 切换到 fight，primary target 固定为误伤责任角色；
7. NPC 的后续战斗输入仍通过同一个 InputBuffer、CommandMatcher、BodyWorld 和 CombatWorld。

NPC 不在受击的同一帧瞬间反击，避免 actor 遍历顺序改变结果。若责任角色通过 tag 暂时退场，
NPC 保留对该角色的主要仇恨；ruleset 的 `teamLiability` 可以允许它暂时攻击责任队伍的当前 active
fighter，防止攻击者用换人永久逃避后果。

### 9.3 仇恨、多人关系与退出

`AggroLedger` 保存按责任角色分开的 hostility score。多个角色先后误伤同一 NPC 时，目标选择按
伤害、最近命中、当前威胁和可达性计算，但第一责任者不会因一次轻微擦伤立即被随机替换。

- 责任角色再次造成伤害会提高并刷新 hostility；
- NPC 被其他参战者保护或再次攻击时可以改变次级目标；
- 原对局结束、主要责任者 KO、hostility 衰减完成或 NPC 主动撤离后进入 `withdrawing`；
- 完成撤离后恢复普通 Gameplay CPU，不因参战永久失去原剧情状态；
- 关系或 grievance 效果在 session 结算时最多提交一次，不能按每个 hit 重复累加。

中立 NPC 不自动加入受害者敌对方的 roster，也不获得 Tag/Assist 能力；它是带明确 hostility edge
的临时参战者。正式队伍胜负默认仍只由 roster participant 决定，incidental NPC 被 KO 不直接判定
原队伍胜负。

### 9.4 能力降级与连锁混战

只有具有有效 schema v2 combat profile 和 `realCombatReady` 的 NPC 才能进入真实战斗。缺少完整
格斗能力或素材的角色被误伤后只能使用退避、逃跑、求助、愤怒表现或离开场景等合法降级，不能
用 presentation attack 冒充真实反击。

DesktopBrawl 可以允许反击再次误伤其他中立角色，形成可观赏的连锁混战，但必须由全局
`NeutralEscalationPolicy` 限流：

```text
NeutralEscalationPolicy
  enabled
  joinOnFirstDamagingHit
  teamLiability
  cascadeEnabled
  maxIncidentalCombatants
  maxCascadeDepth
  hostilityDecayFrames
  reactionDelayFrames
```

第一轮默认：DesktopBrawl 开启、`joinOnFirstDamagingHit = true`、`teamLiability = true`、允许连锁，
但 `maxIncidentalCombatants = 4`、`maxCascadeDepth = 2`。FlatArena Balance 和正式竞技 round 默认关闭
collateral escalation；其旁观角色不可受竞技攻击影响，以保证角色平衡结果可比较。

### 9.5 HUD 与可读性

uninvolved NPC 不显示战斗 HUD。首次误伤后先显示短暂警觉/责任者指示；正式转为
incidentalCombatant 时才显示 HP、Power、临时敌对标记和 primary offender 方向。撤离或仇恨结束后
HUD 消失。所有状态来自不可变 RenderSnapshot，渲染器不能决定 NPC 是否参战。

## 10. 连段、取消与受身

### 10.1 长连段的确定性保护

第一版支持长连段和 tag/assist 连携，但每套连段都由 `ComboState` 统一管理：

- 稳定 `comboID`、命中数和初始攻击者；
- 逐击 damage scaling，第一轮候选从 100% 递减，最低 25%；
- hitstun scaling，使后续攻击逐步更难连接；
- `JuggleBudget`，每个浮空攻击显式消耗点数；
- 同一 move 重复使用产生额外修正；
- wall bounce 和 ground bounce 每套连段分别限制次数；
- assist/tag 连携具有额外 proration；
- 超级技只有显式声明的部分可以突破普通最低伤害；
- 脱离 hitstun、合法受身或超过 combo gap 后，以确定规则结束连段。

取消由数据中的 cancel graph 声明。第一版允许 normal → special、特定 normal chain、爆气取消和
显式 tag cancel，但不根据动画文件名或人物身份推导。CPU rollout、checkpoint 和 replay 必须保存
完整 ComboState。

### 10.2 复杂受身的有限选项

地面受身第一版固定为四种可见选择：原地、向前、向后、延迟。空中允许一次方向受身，但必须
满足招式属性、受身窗口和剩余 JuggleBudget。各选项必须有明确代价：

- 快速受身容易被预判压制；
- 后受身获得距离，但更接近场地软边界；
- 前受身可以改变相对位置，但承担被投风险；
- 延迟起身打乱固定节奏，但放弃立即行动。

受身方向来自映射后的逻辑输入。第一版不加入角色专属隐藏受身规则；所有合法窗口进入
RenderSnapshot 的调试信息和 Harness trace。

空中受身不是“按住任意键自动脱离”。第一版基线只允许角色在 hitstun 最后 12 个逻辑帧内，
以一次新的逻辑按键按下沿触发；同时必须仍在空中、尚有 JuggleBudget，且本连段没有使用过空中
受身。成功后给予 10 个逻辑帧的受身保护。同一按键从窗口外一直按住、已经耗尽浮空预算或同一
连段第二次申请都必须失败。这些数字可由模拟器调参，但“窗口、按下沿、预算和每连段一次”四项
约束不能由角色数据绕过。

## 11. 战斗 HUD

进入 CombatSession 后，每名当前在世界中的参战角色头顶显示：角色/队伍标识、HP、延迟掉血
表现条和三格 PowerGauge。active fighter 显示完整 HUD；assist/tag-in 入场时显示；完全 standby
的角色改为 active HUD 旁的紧凑队伍状态，不在不存在的世界坐标上悬浮。

- HUD 锚定角色世界包围盒上方，再由 renderer 做只读屏幕安全区约束；
- 多名角色靠近时按稳定 EntityID 错层，不能随机跳动或完全覆盖；
- 角色离开当前显示器时，在边缘显示方向和简化 HP/Power；
- 真实 HP/Power 与延迟视觉条分离，逻辑值来自同一 RenderSnapshot；
- renderer 不能通过 HUD 写回 HP、Power、队伍状态或世界位置；
- 退出 CombatSession 后 HUD 消失，普通 Story attack 不显示战斗 HUD。

RenderSnapshot 必须提供不可变的 `CombatHUDSnapshot`；NullRenderer 和 Core Animation adapter
消费相同值，启用或禁用 HUD 不得改变 world digest。

## 12. 飞行道具与独立效果资源

远程攻击至少需要以下稳定资源 ID：

```text
lin_daiyu/falling_petals_cast
effect/petal_spawn
projectile/petal_loop
effect/petal_hit
effect/petal_guard
effect/petal_clash
effect/petal_expire
```

人物 cast 动画只表现人物、衣袖、手帕和施法动作。离开人物身体的花瓣不得烘焙进人物 H3 帧。
投射物的坐标、朝向、速度、寿命、碰撞 mask 和命中 ID 来自 BodyWorld/Combat，不来自播放器。

飞行道具第一版支持：命中角色、被防、同级互消、寿命到期和越界消散。反射、吸收、追踪、
多级耐久和穿透留待后续；只有新角色确实需要这些决策时才扩展契约。

### 12.1 射程是招式契约，不是桌面大小

每个 schema v2 飞行道具必须显式声明有限的 `maxTravelDistance`。它表示从该枚投射物出生点开始
累计的世界空间路程，不是“当前显示器宽度”，也不是只计算水平坐标差。每一枚投射物独立计程；
穿过显示器接缝、目标换屏、窗口移动或世界边界扩大都不会重置或增加射程。

投射物在以下条件中最先发生的一项结束：

1. 累计路程达到 `maxTravelDistance`；
2. 年龄达到 `lifetimeFrames`；
3. 离开合法 BodyWorld 边界；
4. 按招式规则在命中、被防或互消后销毁。

最后一个 60 Hz 逻辑步必须截断到剩余射程，允许在端点前或端点上命中，但不能先越过端点再于
下一帧消失。旧 schema v1 缺少该字段时只保留 lifetime-only 兼容行为；它不得因此被宣称为新的
`realCombatReady` 内容。碰撞、回放与 CPU 可行性判断必须读取同一个 effective travel distance，
禁止 CPU 另写一个“看起来差不多”的全局射程。

第一轮内容合同基线为：

| 招式/投射物 | `maxTravelDistance` | 设计用途 |
|---|---:|---|
| 林黛玉 `falling_petals` 单枚花瓣 | 360 | 中远距离路线限制；不是跨多屏狙击 |
| 摔碗类攻击的每只碗 | 240 | 近中距离爆发；多只碗分别从各自出生点计程 |

这些是模拟器首轮调参值，不是所有角色共享的常量。以后可以根据启动、速度、能量、伤害、收招和
命中率单独调整，但美术帧宽、屏幕分辨率和显示器数量不得暗中改变有效射程。

## 13. Gameplay CPU 与可观赏性

### 13.1 两层决策

`ClassicCombatCPU` 继续负责已经进入战术战斗后的招式选择；它上面增加
`ClassicGameplayCPU`，先决定当前活动，再委派给专用 planner：

```text
ClassicGameplayCPU
  ActivityArbiter
  CombatPlanner        -> ClassicCombatCPU
  ExplorationPlanner   -> DynamicSurfaceGraph
  WindowPlanner        -> inspect/perch/jump/pull/damage intent
  ResourcePlanner      -> reserve/spend/rest preference
  TeamPlanner          -> tag/assist/burst policy
```

ActivityArbiter 的候选包括 fight、explore、interact_window、interact_prop、perform、rest 和
observe。普通桌面生活中可以在这些活动之间选择；正式竞技 round 激活时 ruleset 把顶层活动限制为
fight 及合法的战术地形动作，CPU 不能为了探索而放弃比赛。

uninvolved NPC 没有合法 combat target；收到有效 collateral hit 后，`alerted` 事件以高优先级中断
当前 commitment，CombatEscalationSystem 提供 offender target，随后才允许 CombatPlanner 运行。

活动决定具有 1–3 秒的 `commitment`，只有玩家输入、受到攻击、路径失效、目标消失、窗口关闭或
更高优先级 session event 才能提前中断，避免 CPU 每几帧来回改变主意。

### 13.2 先可行，再有趣

动作选择固定为：

```text
Legal candidates
  -> safety / feasibility filter
  -> base utility
  -> minimumViability gate
  -> variety / personality / spectacle rerank
```

`novelty` 和 `spectacle` 不能救回明显危险或无效的动作。竞技漏洞搜索策略可以把娱乐权重设为 0，
但自主桌宠策略必须在通过 minimumViability 后考虑可观赏性。

### 13.3 ActionHistory 与重复控制

ActionHistory 保存最近 10–30 个语义行为，不只保存 moveID。每个 Move/GameplayAction 声明
`family`，例如 fast_melee、heavy_melee、throw、projectile、movement、guard、special、tag、
assist、window_interaction。CPU 计算：

- 连续同动作的递增惩罚；
- action family entropy；
- 2-gram / 3-gram sequence repetition；
- 最近特殊技、换人、同伴和窗口互动频率。

用三个名字不同但用途相同的快速拳，不能绕过重复惩罚。

远程动作还要经过“实际可达 + 风格许可”两层约束：目标超出该招式的有效射程时，CPU 不得把它
当作可命中的进攻；目标可达时，balanced、normal 等普通人格若刚使用过 projectile family，也要
短暂退出该 family，主动接近或选择其他可行动作，直到历史窗口产生足够的非远程变化。只有配置中
明确把 projectile 作为主要偏好的 zoner 人格可以维持持续远程压制，但它仍受射程、Power、收招、
重复惩罚和 minimumViability 约束。角色不能仅因“当前唯一能碰到对手的是远程招式”就永久循环
同一飞行道具。

### 13.4 Spectacle、探索与人物风格

Spectacle 是 CPU utility，不是命中或胜负规则。大击退、跨窗追击、窗口跳跃、换人连携、超级技
和很久未出现的动作可以增加 spectacle；重复拳、长时间原地不动和无意义换人会降低它。

ExplorationMemory 按 Surface 保存 lastVisitedFrame、visitCount、timeSpent 和 interestingEvents；
WindowInterest 根据新鲜度、移动、大小、前台状态、可拉动/可表现破坏以及最近访问计算。窗口破坏
仍只产生 Living Desktop overlay 表现，不改外部应用，并且必须通过 PlatformAction 与权限策略。
WindowPlanner 只能给出意图；`WindowInteractionPolicy` 在执行 seam 再次检查总开关、前台保护、
用户活跃状态、冷却、每分钟上限、能量成本和消费后最低余额。被策略拒绝的动作不能扣能量，
也不能用其他 DesktopAction 名称重试绕过限制。

`boredom` 在长期停留于同一 Surface、同一对手或同一 action family 时增加；访问新 Surface、
切换合法 action family 或完成窗口互动时下降。它只能提高 explore/window-play 的活动 utility，
不能越过 minimumViability 强迫角色执行危险动作。

人物差异来自 `CharacterGameplayStyle`，禁止 `if actor == ...`：

| 风格 | 林黛玉 | 武松 |
|---|---|---|
| Combat | medium | high |
| Explore | medium | medium |
| Destruction | very low | high |
| Risk | low | medium |
| EnergyReserve | high | low-medium |
| Spectacle | restrained | forceful |

这些只是第一轮相对倾向，不能越过招式合法性或改变角色规则数据。

CPU 参数分成 `CombatWeights`、`ExplorationWeights`、`EntertainmentWeights` 和 `ResourcePolicy`；
人物只选择或覆盖风格参数，不复制 planner 实现。竞技漏洞搜索使用同一 planner，但关闭
EntertainmentWeights，并把胜负/资源/风险权重提高。

### 13.5 Checkpoint 与未来教师数据

GameplayObservation 至少包含 combat/team/combo state、CombatParticipation、AggroLedger、Energy、
boredom、commitment、ActionHistory、ExplorationMemory、SurfaceGraph、WindowInterest 和
CharacterGameplayStyle。GameplayDecision 记录
活动候选分布、入选 planner、合法动作集合、基础 utility、rerank 分量和最终逻辑输入/intent。

Energy、ActionHistory、commitment、boredom、探索记忆、队伍状态、NPC 参与状态、仇恨、升级策略和
planner 决定全部进入
checkpoint/record/replay。未来模型只能替换决策 policy，不能绕过这些规则或直接写世界。

## 14. 模拟器平衡流程

### 14.1 三种独立 verdict

- `FlatArena Balance`：固定平地、固定边界和出生距离，是角色数值平衡的权威结果；
- `Desktop Robustness`：窗口顶沿、多屏、缝隙、移动窗口、拖拽和抛掷，只证明桌面环境中规则
  不失效，不改变 FlatArena 的基础胜率结论；
- `Autonomous Entertainment`：衡量动作多样性、探索、窗口互动、表演事件和无意义停顿，不替代
  前两项 verdict。

FlatArena 必须使用 entertainment 权重为 0 的 exploit-search/adversarial policy 寻找最优策略漏洞，
同时使用完整风格 CPU 验证实际自主体验。不能用“CPU 为了好看主动选了次优动作”掩盖失衡。

### 14.2 策略族与矩阵

不能只让两个相同 CPU 自我对战。每个角色至少面对：rush、turtle、zoner、throw-heavy、
anti-air、assist-heavy、random 和 MCTS 策略。每个组合执行：

- 双方换边和 facing 镜像；
- 近、中、远三种起始距离；
- 多个固定 seed；
- renderer on/off；
- 20/40/60/120 Hz render sampling；
- record → replay；
- 同伴启用和禁用两组对照。

Autonomous Entertainment 另外执行 balanced、rushdown、explorer、zoner、heavy、resource-hoarder
和 resource-spender 风格矩阵，确认娱乐权重不会破坏最低可行性，也不会让所有人物收敛到同一行为。

DesktopBrawl 还必须覆盖：近战误伤、projectile 误伤、assist 误伤、有 owner 的环境伤害、同帧多人
误伤、责任者换人、非 combat-ready NPC 降级、NPC 二次误伤、达到人数/深度上限、hostility 衰减
撤离，以及全部场景的 record → replay。相同输入下参战帧、责任者、目标和最终参与集合必须一致。

### 14.3 指标

- 胜率、平均回合长度、超时率、双败率；
- 立回获胜、每次 opening 的平均伤害、连续压制时间；
- 每招选择、命中、防御、落空、确反和伤害贡献；
- 站防、下防、投技、对空和起身结果分布；
- projectile spawn/hit/block/clash/expire 和同屏峰值；
- projectile 按 move 的选择/伤害占比、出生距离、实际飞行路程、命中距离和消散原因；
- 近/中/远起始距离的远程命中率，以及跨显示器接缝前后射程不得重置；
- assist call/hit/interrupted/whiff、冷却利用率及其伤害贡献；
- tag 成功/被打断/防御换人、standby 时长和 active/bench HP 分布；
- Power 的获得、消费、溢出、远程占比、super/power-up/burst 选择率；
- combo 长度、damage/hitstun scaling、juggle 消耗、bounce 和受身结果；
- 角落占用、无法接近、永久防御和循环状态；
- world digest、CombatEvent、HP、BodyState 和结果一致性；
- simulation p50/p95/max，和 render/platform polling 分开记录；
- action-family/move entropy、最长重复序列和 2-gram/3-gram 重复率；
- reachable surface/screen/window coverage、surface transition 和垂直探索；
- spectacle events/minute、idle/combat/exploration/window-play ratio；
- activity commitment 完成/中断/抖动次数和 minimumViability 过滤结果；
- Energy reserve deviation、低能量误消费和满能量长期不消费；
- window pull/damage intent、策略拒绝原因、实际执行次数、每分钟频率与能量占比；
- 用户活跃/前台保护期间实际窗口拉动次数必须为 0；
- collateral hit 来源、NPC alerted/join/withdraw 帧、primary offender 和目标切换；
- incidental combatant 峰值、cascade depth、被策略拒绝的升级和仇恨持续时间；
- FlatArena 中 incidental join 次数必须为 0，DesktopBrawl 不得超过配置上限。

首轮警戒线：镜像胜率 `50% ± 2%`；跨角色目标 `45%–55%`，探索期最多接受 `40%–60%`；
单招长期贡献超过总伤害约 35%、单一决策在多数状态成为最优、无限连段或永久封锁都必须调查。
这些是异常探测线，不是为了追求数字好看而机械修改角色特色。

团队正式超时按队伍成员剩余 HP 总和判定，不按场上单个最高 HP 角色判定；总和相同的队伍并列，
不得因 actor 遍历顺序产生唯一胜者。短时 simulator evaluation window 只用于快速评分，报告中必须
与正式回合超时分开命名，不能把 10 秒评估窗口冒充 99 秒正式对局。

### 14.4 模拟器不能替代的验收

模拟器能发现数值统治、死循环、距离死区、CPU 漏洞和非确定性，但不能证明：

- 人类是否看得懂启动和收招；
- 操作映射是否舒服；
- 打投、防反和同伴夹击是否主观公平；
- 命中停顿、音画反馈和角色表演是否令人满意。

因此每次数值冻结还需要人工操作验收；最终视觉加入后需要再次检查可读性，但不重新以视觉
回调定义规则。

## 15. 从规则到最终美术的门序

1. 冻结第一版通用规则、输入槽、GameplayEnergy、队伍、换人、同伴、中立 NPC 升级、连段和受身约束；
2. 完成两名角色所有 Move Intent Record；
3. 完成 Gameplay CPU 的 activity、resource、history、exploration 和 team 决策契约；
4. 用合成方块、box overlay 和临时效果跑通战斗；
5. 完成单元、属性、回放和竞争/娱乐策略矩阵测试；
6. 根据模拟器证据调整数值，每次只改一个主要维度；
7. 冻结 gameplay contract 和资源 ID；
8. 为每名角色编写视觉契约及原著/项目改编边界；
9. 首批只制作 `combat_ready`、一个普通攻击、轻受击、击倒、倒地和起身；
10. 验证真实 hit → KO → recover；
11. 制作 projectile、assist、guard 和 impact 独立透明资源；
12. 分批制作其余动作，逐张确认 canonical、动作端点和 H3 暂存帧；
13. 运行真实 WebP、Core Animation、人工操作和长程平台验收。

最终美术必须服从已冻结的逻辑节拍：启动轮廓对应 startup，身体或道具的可见端点对应有效
HitBox，收招能够解释 recovery。美术资源不能写入公开仓库；公开仓库只保存 schema、资源 ID
契约、合成测试资源和通用运行时代码。

### 15.1 参考实现采用范围

- FightingICE `188fca0c` 的 `MotionData` 与动作合法性检查：参考 start/hit/guard/defender energy delta 和资源不足
  时拒绝动作；不复制其角色或内容数据；
- IKEMEN GO `76dd472f` 的 `TagIn`/`TagOut`：参考 active/standby、partner state、控制权交接和 tag HUD 数据组织；
- IKEMEN GO power、air juggle、ground/air recover：参考规则维度的完备性，不兼容其内容格式；
- 所有参考规则进入 MyPet 自己的深 Module，通过统一 Interface 暴露给 CombatSession、CPU、
  Harness 和 renderer，禁止把参考项目的全局状态或脚本例外扩散到调用者。

## 16. 讨论后需要冻结的决定

以下项目在进入实现前仍保持显式开放：

1. 首局采用单回合还是传统三局两胜；
2. 回合时长及超时判定；
3. GameplayEnergy 的精确获得/恢复/消费、战斗外持久化、攻击爆气持续时间和防御爆发惩罚；
4. 同伴受击只延长冷却，还是同时给 active fighter 带来少量代价；
5. tag/assist 公共冷却、handoff frame 和防御换人的精确成本；
6. 防御采用后方向自动站防 + 下后低防，还是独立 guard 逻辑控制；
7. cancel graph、damage/hitstun scaling、JuggleBudget 和 bounce 的第一组参数；
8. 四类地面受身及空中受身的精确窗口和无敌帧；
9. 林黛玉和武松各自的 HP、移动速度与完整初始 frame data；
10. 武松工作招式名及其原著/项目改编边界；
11. 最终队伍关系与同伴选择是否受剧情关系限制；
12. minimumViability 阈值、Activity commitment 和竞技/娱乐两套 CPU 权重；
13. Surface/Window interest、boredom、spectacle 与 coverage 的首轮目标区间；
14. WindowInteractionPolicy 的成本倍率、安全下限、冷却和每分钟频率默认值；
15. NeutralEscalationPolicy 的人数、深度、反应延迟、仇恨衰减和责任队伍规则。

这些决定冻结后，再进入代码和模拟器阶段；美术始终位于数值与规则稳定之后。
