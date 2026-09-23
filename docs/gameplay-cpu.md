对。你这里真正需要的不是 LLM、RL 或“模型 AI”，而是传统游戏开发里的 **Game AI**：规则、搜索、预测、路径规划、状态机和评分函数。

而且你这个场景比普通《街霸》更像：

> **2D 格斗 + 清版动作 + 平台游戏 + 动态地形。**

我看了 FightingICE 的 `MctsAi23i`、OpenBOR、Surfacer、F.LF、IKEMEN，以及 FightingICE 的 RHEA 系列实现后，我认为最适合 MyPet 的结构不是单一 FSM，而是：

```text
              Combat Brain
                   │
        ┌──────────┴───────────┐
        │                      │
   Terrain Planner        Tactical Planner
 SurfaceGraph + A*        Utility + MCTS
        │                      │
        └──────────┬───────────┘
                   ▼
              Action Intent
                   │
            Command Synthesizer
                   │
                   ▼
             FighterInput
                   │
             InputBuffer
                   │
          MyPetCombat / BodyWorld
```

其中**地形用 A***，**战术先用 Utility AI**，复杂近战再用**短视野 MCTS**。这是我目前最推荐的最终方向。

---

# 一、传统格斗游戏的电脑其实怎么“思考”

最传统的 CPU 并不会看画面。

它直接知道：

```text
自己：
position
HP
current state
current move
current frame
velocity
ground/air
energy

敌人：
position
HP
state
move
move frame
velocity

游戏：
distance
facing
corner
projectile
```

然后做类似：

```text
敌人距离 < 50
敌人正在 recovery
自己可以行动
→ attack

敌人 attack 已启动
攻击还有 8 frame 到达
→ guard / dodge

敌人距离 > 300
→ approach

自己血少
→ defensive
```

这其实就是传统 CPU AI 的核心。

**重点不是 FSM 本身，而是“读取精确的游戏状态，然后选择合法动作”。**

IKEMEN/MUGEN 生态就是这种思路：角色状态脚本可以根据 `AILevel`、距离、状态、
MoveType 等条件进入不同 state。IKEMEN 当前运行时也保存独立 `aiLevel` 和
`AiInput`。([GitHub][1])

所以最简单的传统 AI：

```text
Sense
 ↓
Rules
 ↓
Action
```

就已经能打得不错。

---

# 二、OpenBOR 更接近你现在的桌面世界

OpenBOR 非常值得我们借鉴，因为它不是纯 1v1 格斗，而是 beat-em-up。

它直接定义了：

```text
CHASE
CHASE_X
CHASE_Z

AVOID
AVOID_X
AVOID_Z

WANDER

IGNORE_HOLES

DODGE
DODGE_MOVE

AGGRESSION
```

甚至 `DODGE_MOVE` 的注释本身就是：

> 对跳跃攻击尝试横向躲避，对近战尝试后退。

这已经是一个完整的传统 Game AI 雏形。OpenBOR 还显式区分 hole avoidance，所以“环境危险”本来就是 AI 决策的一部分。([GitHub][2])

你可以把它理解为：

```text
Movement AI
+
Attack AI
+
Defense AI
```

而不是：

```text
一个神经网络 → 输出动作
```

对于 MyPet，这个思想非常合适。

---

# 三、真正高级的传统方案：FightingICE 的 MCTS

这个项目对我们特别重要。

我直接看了当前 `MctsAi23i` 的源码。

它做的不是训练模型，而是：

```text
当前游戏状态
    ↓
复制游戏世界
    ↓
尝试不同动作
    ↓
模拟未来
    ↓
比较结果
    ↓
选最好的动作
```

也就是：

**CPU 在脑子里快速打几遍未来。**

[MctsAi23i 源码仓库](https://github.com/TeamFightingICE/MctsAi23i?utm_source=chatgpt.com)

它的实际实现非常简单。

首先把当前状态**先模拟未来 14 frame**：

```java
simulatorAheadFrameData =
    simulator.simulate(
        frameData,
        playerNumber,
        null,
        null,
        14
    );
```

然后根据：

```text
ground / air
energy
```

筛选自己真正可以使用的 Action。

例如地面状态才考虑：

```text
walk
dash
jump
back jump
guard
throw
stand A
stand B
crouch A
...
special
```

然后建立 MCTS。

当前参考实现参数甚至非常浅：

```text
tree depth = 2
simulation horizon = 60 frames
iteration limit = 23
```

每次 playout：

```text
我的动作序列
+
随机敌人动作序列
        ↓
Simulator.simulate(... 60 frames)
```

评价函数非常朴素：

```text
Score =
    对手损失 HP
    -
    自己损失 HP
```

更精确地说，它看的是双方 HP 变化差。

MCTS 用 UCB1：

$$
UCB = \bar X_i + C\sqrt{\frac{2\ln N}{N_i}}
$$

在“继续测试未知动作”和“使用已经证明不错的动作”之间做平衡。

最后选择：

**访问次数最多的动作。**

这就是非常纯粹的传统“智能”。

FightingICE 本身就是格斗 AI 研究平台，并提供游戏状态与 simulator，因此大量工作都建立在“复制世界 → 快速模拟”这个思想上。([GitHub][3])

---

# 四、你的 BodyWorld 天然非常适合这种算法

我们刚确定的新架构有一个巨大优势：

```text
MyPet2D
BodyWorld
fixed 60Hz
deterministic
headless
snapshot/replay
```

这恰恰就是 MCTS 最需要的。

以后可以直接：

```swift
let simulatedWorld = world.snapshot()

simulate(
    simulatedWorld,
    myAction: .heavyPunch,
    opponentAction: .guard,
    frames: 45
)
```

几十微秒到几百微秒跑一次纯逻辑模拟。

所以 MyPet 的 CPU 可以真的“想”：

```text
我跳过去攻击会怎么样？

→ 会掉到 Chrome 下面
→ -300 terrain score

那从 VSCode 窗口跳过去呢？

→ 32 frames 到达
→ 对方可能正在 recovery
→ expected +55 HP advantage

那直接从当前窗口重拳？

→ 打不到
→ recovery 时会被反击
→ -80
```

这才是你说的**真正意义上的智能**。

不是模型生成一句：

> “我决定跳过去攻击。”

---

# 五、但你的世界不能只用 MCTS

这是最重要的一点。

如果世界只是：

```text
────────── ground ──────────

A                       B
```

MCTS 很容易。

你的世界是：

```text
 ┌──── Safari ──────────┐
 │                      │
 └──────────────────────┘
           A

                         ┌──── VSCode ────┐
                         │                │
                         └────────────────┘
                                B

════════ monitor 1 ═══════

                     ═══════ monitor 2 ═════
```

如果让 MCTS 自己探索：

```text
left
right
jump
drop
attack
guard
...
```

然后一直探索到另一个窗口，branching factor 会爆炸。

所以：

> **寻路和战斗必须分层。**

---

# 六、桌面地形应该采用 Surface Graph

这里我找到一个和你非常契合的项目：

**Surfacer**。

[SnoringCatGames/surfacer](https://github.com/SnoringCatGames/surfacer?utm_source=chatgpt.com)

它解决的是：

> 2D Platformer AI 怎么在平台之间自己走、跳、掉落。

它不是把世界做成传统 NavMesh。

而是构建：

**Platform Graph / Surface Graph。**

Surfacer 把 floor / wall / ceiling 表示成 surface，再把可执行运动表示成 graph edge；运行时通过 A* 找路径。它支持 walk、jump、fall 等不同类型的边，而且 movement parameters 是 per-character 的。([Godot Engine][4])

这几乎就是我们桌面窗口需要的模型。

---

# 七、把 macOS 桌面建成图

例如当前桌面：

```text
S1 = Monitor floor

S2 = Chrome top

S3 = VSCode top

S4 = Finder top
```

AI graph：

```text
          jump
 S2 ─────────────→ S3
 │                  │
 │ drop             │ jump
 ↓                  ↓
 S1 ←────────────── S4
        walk
```

Edge 不是简单：

```text
A → B
```

而是：

```text
NavigationEdge {
    fromSurface
    toSurface

    action:
        walk
        jump
        drop
        climb
        perch

    launchPoint
    landingRange

    expectedFrames
    risk
}
```

这非常关键。

因为 AI 不是在二维像素中找路：

> 从 (1234, 567) 到 (1750, 430)。

它是在找：

> **从 Chrome 顶部通过 JumpEdge 跳到 VSCode 顶部。**

Surfacer 就采用 surface nodes + movement trajectories + A* 的思路。([Levi DevLog][5])

---

# 八、你的窗口是动态地形

Surfacer 老版本主要针对静态平台，而你的窗口会：

```text
移动
缩放
最小化
关闭
跨屏
```

所以我们要改成：

```text
DynamicSurfaceGraph
```

但其实不用每帧全部重建。

你的 `WindowWorld` 已经有：

```text
windowID
bounds
revision
```

正好可以做：

```text
Window changed
      ↓
只 invalidate 与该 window 有关的节点/edge
      ↓
重新计算 local edges
```

例如 Chrome 移动：

```text
Chrome Surface revision
     12 → 13
```

那么：

```text
Chrome → VSCode jump edge
Chrome → floor drop edge
Chrome walk interval
```

重新算。

别的窗口不用动。

---

# 九、A* 找的不是“敌人位置”，而是最佳战斗位置

这又是普通平台寻路和 Combat Navigation 的区别。

假设敌人在：

```text
B x=1200
```

武松的拳最佳距离：

```text
60~90 px
```

那么 AI 不应该寻路到：

```text
B.x = 1200
```

而应该选择：

```text
CombatAnchor

target.x - 75
```

例如：

```text
             Target
               B
               │
      [attack range]
        ←─────→
           A
```

所以 Tactical Brain 首先生成几个候选位置：

```text
left melee anchor
right melee anchor
long-range anchor
escape anchor
high-ground anchor
```

然后 SurfaceGraph 判断：

```text
哪个 anchor 可达？
需要多少 frame？
有多危险？
```

A* cost 不应该只有距离。

应该类似：

$$
Cost =
T_{travel}
+ w_j C_{jump}
+ w_r Risk
+ w_e EdgeDanger
+ w_m MovingSurfaceRisk
$$

比如：

```text
走 80 frames
风险很低
= 80

跳过一个大 gap
40 frames
但死亡风险 100
= 140
```

CPU 自然选择安全路线。

---

# 十、真正的“战斗脑”我建议用 Utility AI

我不会第一版就全部用 MCTS。

第一层 tactical decision 最适合：

**Utility AI。**

也就是说每一个候选行为都算一个分数。

例如：

```text
Approach
Retreat
Guard
Dodge
Jump
LightAttack
HeavyAttack
Throw
Special
Reposition
```

假设当前：

```text
distance = 72

enemy:
  recovery = 15 frames

self:
  light startup = 4
  heavy startup = 11

edge behind self = 30px
```

那么：

```text
LightAttack = 0.90
HeavyAttack = 0.78
Approach = 0.10
Retreat = 0.15
Guard = 0.20
```

于是打 light。

Utility score 可以很明确：

$$
U(move)=
P(hit)\times Damage
+ FrameAdvantage
+ PositionGain
- WhiffRisk
- CounterRisk
- TerrainRisk
- ResourceCost
$$

全部是**确定性计算**。

没有 ML。

---

# 十一、P(hit) 甚至不用“概率模型”

这是有意思的地方。

因为我们有 simulator。

可以直接预测：

```text
attack active frames:
6...8

预测 opponent 未来 position:
frame 6 → x 141
frame 7 → x 138
frame 8 → x 134
```

然后：

```text
HitBox(move, frame 7)
    intersects
PredictedHurtBox(enemy, frame 7)
```

那么：

```text
canHit = true
```

如果考虑敌人的多个可能动作：

```text
enemy:
  stand
  attack
  guard
  retreat
```

就模拟四次。

例如：

```text
lightPunch:

enemy stay       +40
enemy attack     +20
enemy guard      -5
enemy retreat    -15

expected score = ...
```

这实际上已经很接近 MCTS 了。

---

# 十二、然后才在“近战局部”使用 MCTS

所以最终我建议：

```text
距离很远 / 不同平台
      ↓
Surface Graph + A*

进入战斗区域
      ↓
Utility AI 筛出 Top K

例如：
LightAttack
Guard
Dodge
Throw
HeavyAttack
      ↓
短视野 MCTS
      ↓
选动作
```

这样 MCTS branching factor 很小。

不是：

```text
全世界 30 个窗口
×
所有 movement
×
20 个 attacks
×
所有角色
```

一起搜。

而是：

```text
最多 5~8 个 tactical candidate
×
敌人 4~6 个可能 response
×
30~90 frames
```

这就非常便宜。

---

# 十三、可以直接复刻 FightingICE 的第一版

实际上我们第一版甚至不需要做复杂 MCTS。

可以直接参考 `MctsAi23i`：

```text
legalActions()
       ↓
root children = 每个 action
       ↓
UCT
       ↓
simulate 60 frames
       ↓
score
       ↓
best action
```

但是把评分从：

```text
enemy HP loss
-
self HP loss
```

升级成：

```text
score =
  1.0 * hpAdvantage
+ 0.2 * positionalAdvantage
+ 0.3 * surfaceSafety
+ 0.2 * frameAdvantage
- 0.5 * fallRisk
- 0.2 * edgeRisk
```

这样它自然开始理解桌面地形。

比如：

```text
一拳打中对方：
+40

但自己打完会从窗口掉下去：
-150
```

它就不会乱打。

---

# 十四、敌人的行为也不用精确预测

FightingICE 的 MCTS reference AI 有个很朴素的技巧：

**对手动作随机采样。**

它的 rollout 中：

```text
opponent actions
=
从合法动作随机抽
```

这种算法已经可以工作。

我们可以做得好一点。

建立一个：

```text
OpponentActionModel
```

但仍然完全规则化：

```text
距离近：
40% attack
30% guard
15% retreat
15% throw

距离远：
45% approach
20% jump
20% projectile
15% wait
```

再根据对方角色 personality 调整。

这不是机器学习。

只是：

```text
weighted action distribution
```

---

# 十五、甚至还有 RHEA，可以作为 MCTS 的替代

我也看了 FightingICE 社区里的：

**Enhanced Rolling Horizon Evolution Algorithm**。

[GameAI-FightingAI / RHEA 源码](https://github.com/DRL-CASIA/GameAI-FightingAI?utm_source=chatgpt.com)

它不是训练神经网络。

思路是：

```text
生成很多未来动作序列：

A:
attack → guard → attack

B:
dash → throw → retreat

C:
jump → attack → dodge

           ↓

全部用 Simulator 执行

           ↓

给每条序列评分

           ↓

保留好的
mutation / evolution

           ↓

执行最优序列第一个动作
```

然后下一次重新规划。

这叫：

**Rolling Horizon Evolutionary Algorithm。**

它的源码就是把一个 `Individual` 表示成 action genes，然后 rollout，通过 simulator 得到 reward，再 mutation。([GitHub][6])

对于你的场景：

MCTS 会更直观，我会先做 MCTS。

RHEA 后面可以作为第二种 CombatPolicy 插件。

---

# 十六、真正适合 MyPet 的最终 AI 架构

我建议定成四层。

| 层                    | 算法                         | 解决问题         |
| -------------------- | -------------------------- | ------------ |
| **Target Selection** | Utility scoring            | 我应该打谁        |
| **Navigation**       | Dynamic Surface Graph + A* | 怎么到他那里       |
| **Tactical Combat**  | Utility + shallow MCTS     | 现在应该打、防、躲还是撤 |
| **Execution**        | FSM + CommandSynthesizer   | 真正按键、移动、出招   |

这是非常经典、而且完全 deterministic 的 Game AI。

---

# 十七、多角色情况下“打谁”也应该有评分

你的桌面可能：

```text
武松
孙悟空
猪八戒
明日香
狗
```

不能简单：

```text
nearest enemy
```

Target utility 可以是：

$$
TargetScore =
Threat
+ Reachability
+ Vulnerability
+ Aggro
- PathCost
- CrowdPenalty
$$

例如：

```text
孙悟空：
距离近      +30
HP低         +20
可达         +20
已经被2人围攻 -40
总分          30

明日香：
距离稍远     +10
正在攻击我   +50
可达         +20
总分          80
```

→ 切目标明日香。

这样才会有真正的群战行为。

---

# 十八、还需要一个 Engagement Slot

这是 beat-em-up 很重要、但经常被忽略的东西。

如果 5 个 AI 都执行：

```text
approach target.x
```

最终就是：

```text
AAAAAB
```

全部挤在一起。

应该围绕 target 生成：

```text
        slot top

slot L    B    slot R

       slot far
```

对于你当前 2D 平台其实主要是：

```text
left-near
left-far
right-near
right-far
upper-platform
```

AI 先 reserve 一个：

```text
CombatSlot
```

再向那个位置寻路。

这会立即让群战自然很多。

---

# 十九、窗口地形会产生非常有意思的战术

例如：

```text
             ┌── Chrome ──────┐
             │                │
             └────────────────┘
                  Wu Song

  Asuka
════════ floor ═══════════════════
```

AI 可以计算：

```text
武松在高处

直接跳上去：
cost 60
risk 30

等武松下来：
cost 80
risk 5

从另一个窗口绕：
cost 100
risk 0
```

不同角色可能不同：

```text
Sun Wukong:
mobility high
→ jump

Zhu Bajie:
mobility low
→ wait / find lower path

Asuka:
fast
→ flank
```

你已有的 `mobility`、`impact` 等角色参数，在这里就真正开始产生游戏意义。

---

# 二十、反应系统和“思考系统”要分开

传统游戏 AI 好玩的另一个关键是：

**不能每件事都重新规划。**

需要 Reflex。

例如：

```text
incoming hit in 3 frames
→ block

脚下 surface 消失
→ fall recovery

正在掉出窗口
→ air recovery

player mouse grab
→ suspend AI
```

这类逻辑：

```text
每 60Hz 检查
```

不跑 MCTS。

然后正常 Tactical Planner：

```text
每 4~8 frames
```

重新决策一次。

Navigation：

```text
目标或 surface graph 变化时才重新 A*
```

这样 CPU 非常低。

---

# 二十一、最关键的就是不要让 CPU“作弊”

传统游戏很容易做出这种垃圾 CPU：

```text
玩家按 Attack
同一 frame CPU 就 Guard
```

它看起来强，但不是聪明。

建议每个 Difficulty 定义：

```text
perceptionDelayFrames
decisionInterval
searchBudget
predictionDepth
mistakeRate
```

例如：

```text
Easy:
reaction = 14f
MCTS = off
mistake = 20%

Normal:
reaction = 9f
Utility only

Hard:
reaction = 6f
MCTS 15 rollouts

Very Hard:
reaction = 4f
MCTS 40 rollouts
```

这样提高的是：

**搜索质量和反应速度。**

而不是：

```text
AI 可以违反 recovery
AI 可以瞬间 guard
AI 知道玩家下一帧按键
```

---

# 二十二、我建议我们的第一版这样写

核心接口可以非常简单：

```swift
struct CombatObservation {
    let selfState: FighterSnapshot
    let enemies: [FighterSnapshot]

    let surfaces: SurfaceGraphSnapshot
    let currentPath: CombatPath?

    let legalMoves: [MoveID]
}

protocol CombatPolicy {
    func decide(
        _ observation: CombatObservation
    ) -> CombatDecision
}
```

第一版 `ClassicCombatPolicy`：

```text
1. update target
2. emergency reflex
3. calculate desired combat anchor
4. if anchor unreachable:
       SurfaceGraph A*
5. if not in fighting range:
       follow path
6. else:
       score legal actions
7. take top 5
8. optional shallow MCTS
9. return CombatDecision
10. CommandSynthesizer → FighterInput
```

这就是完整的传统 CPU。

---

# 二十三、一个攻击评分可以直接这样写

例如：

```text
score(move):

+ expectedDamage             × 1.0
+ hitChance                  × 60
+ frameAdvantage             × 2
+ knockbackTowardDanger      × 0.8
+ positionalGain             × 0.4

- whiffRisk                  × 50
- counterRisk                × 60
- startupExposure            × 1.5
- recoveryExposure           × 1.0
- edgeDanger                 × 80
- fallRisk                   × 150
- repetitionPenalty          × 15
```

例如：

```text
Heavy Punch

expectedDamage       +90
hitChance 0.7        +42
frameAdvantage       +10

whiffRisk            -20
counterRisk          -30
fallRisk             -80

total                 +12
```

而：

```text
Light Punch

damage                +40
hitChance             +55
risk                  -10

total                 +85
```

→ Light Punch。

这已经看起来非常“聪明”。

---

# 二十四、我认为最值得直接抄思想的项目

我会按用途来借鉴：

**FightingICE / MctsAi23i**：抄战斗短期搜索。它直接用 simulator、合法动作集合、UCT 和 rollout，是我们 Combat Brain 最直接的蓝本。([GitHub][7])

**OpenBOR**：抄传统 chase / avoid / aggression / dodge / hole awareness。这最适合做“没有进入精细 MCTS 时”的廉价行为层。([GitHub][2])

**Surfacer**：抄桌面地形导航。Surface → trajectory edge → A*，和我们的 WindowWorld 几乎是天然匹配的；尤其应该研究它的 jump/fall edge calculation、movement parameters、surface navigator。([Godot Engine][4])

**F.LF / Project F**：抄“AI 也通过 controller 发按键”这个边界。它的 AI controller 本身提供 `keypress/keyseq`，说明 AI 和玩家可以共用同一种输入层。[Project F / F.LF](https://github.com/Project-F/F.LF?utm_source=chatgpt.com)

**GameAI-FightingAI / RHEA**：以后研究 MCTS 替代方案。它直接进化未来动作序列，再用 simulator 评估，不需要神经网络。([GitHub][6])

---

# 最后的建议

对于 MyPet，我现在会把“自主格斗智能”正式定义为：

```text
                  Classic Combat AI
                         │
            ┌────────────┴─────────────┐
            │                          │
      Dynamic Surface AI          Combat AI
            │                          │
     Surface Graph + A*          Utility scoring
            │                          │
      move/jump/drop             Top-K actions
            │                          │
            │                    Shallow MCTS
            │                          │
            └────────────┬─────────────┘
                         ▼
                  CombatDecision
                         ▼
                 CommandSynthesizer
                         ▼
                    InputBuffer
                         ▼
                     BodyWorld
```

**这不需要任何模型，也不需要训练。**

更重要的是，它会真正利用我们刚刚设计的 deterministic simulator：CPU 不是“猜测哪个动作好”，而是可以把未来 0.5～1.5 秒真正模拟很多遍以后再决定。

我认为这是比 NanoJev/LLM 更适合作为**基础自主战斗大脑**的方向。以后如果要加小模型，也应该只替换 `CombatPolicy`，而不动这一整套传统 Game AI 基础。

[1]: https://github.com/ikemen-engine/Ikemen-GO/blob/develop/src/system.go?utm_source=chatgpt.com "Ikemen-GO/src/system.go at develop · ikemen-engine/Ikemen-GO · GitHub"
[2]: https://github.com/DCurrent/openbor/blob/master/engine/openbor.h?utm_source=chatgpt.com "openbor/engine/openbor.h at master · DCurrent/openbor · GitHub"
[3]: https://github.com/TeamFightingICE/FightingICE?utm_source=chatgpt.com "GitHub - TeamFightingICE/FightingICE · GitHub"
[4]: https://godotengine.org/asset-library/asset/968?utm_source=chatgpt.com "Surfacer: 2D-platformer AI and pathfinding - Godot Asset Library"
[5]: https://devlog.levi.dev/2021/09/building-platformer-ai-from-low-level.html?utm_source=chatgpt.com "How to build a platformer AI: From low-level trajectories to high-level behaviors"
[6]: https://github.com/DRL-CASIA/GameAI-FightingAI?utm_source=chatgpt.com "GitHub - DRL-CASIA/GameAI-FightingAI · GitHub"
[7]: https://github.com/TeamFightingICE/MctsAi23i?utm_source=chatgpt.com "GitHub - TeamFightingICE/MctsAi23i · GitHub"

