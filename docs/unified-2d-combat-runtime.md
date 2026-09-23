# Unified 2D Body, Combat, Physics, and Rendering Runtime

> 状态：实现规格（Design / Implementation Specification），2026-09-23。
>
> 本文定义 Living Desktop 下一代统一游戏底层。它不是“给桌宠附加一个格斗插件”，
> 而是把角色运动、平台物理、碰撞、鼠标抛掷、窗口表面、格斗、人工接管和模拟器
> 收敛到同一个确定性 2D runtime。现有剧情、关系、道具、窗口和内容玩法继续使用
> GameRuntime / GameKernel 的领域模型，不被格斗规则取代。
>
> 本文只描述公开运行时的代码与资源契约。角色美术、内部素材生成和私有 Harness
> 不属于本仓库。

## 1. 目标

完成本设计后，Living Desktop 必须同时满足以下条件：

1. 角色平时的 walk / run / jump / fall / perch / drag / toss 与战斗时的移动、
   击退、倒地使用同一套身体和物理规则。
2. 多个角色共享同一个 2D 世界，同一帧内统一计算支撑面、PushBox、HitBox、
   HurtBox、道具和环境碰撞；不能每个 PetController 自己维护一套位置事实。
3. 现有剧情、Scene、Relationship、Prop、Window、Cast、Pointer Reflex 和
   StoryDirector 继续工作；它们改为调用统一身体执行边界，不重新实现运动。
4. AI 自主战斗和玩家键盘接管使用同一条 FighterInput → InputBuffer →
   CommandMatcher → MoveState 路径。
5. 玩家 HP 归零后不会删除实体，而是经过击飞/倒地 → downed → get-up →
   恢复生命的状态流程。
6. 真实 macOS 和 MyPetSimulation 运行相同的身体、物理、碰撞和战斗实现；
   模拟器不得用“直接改坐标/到时自动成功”冒充真实运动。
7. 渲染完全读取只读快照。渲染后端可以从第一版 Core Animation 替换为 Metal，
   而不修改 GameRuntime、BodyWorld、CombatRuntime、剧情或模拟器。
8. 保留多显示器、窗口顶沿/底沿、窗口移动跟随、窗口消失后掉落、鼠标点击、
   拖拽、抛掷、拉窗和现有抢占规则。
9. 所有逻辑可以 headless、record/replay、固定种子测试。
10. 第一版不要求兼容 MUGEN 文件格式本身；“格斗兼容”指兼容成熟 2D 格斗游戏的
    fixed-frame、command、move timeline、collision、hit resolution、guard、
    hitstop、hitstun、knockback、knockdown、get-up 等运行语义。

## 2. 非目标

以下内容不应混入第一次底层迁移：

- 不实现 MUGEN CNS/AIR/SFF/CMD 的完整导入器；
- 不实现联网对战、rollback netcode；
- 不让真实外部应用窗口受到攻击而改变内容；
- 不要求所有普通角色立即具备完整格斗素材；
- 不用 SpriteKit Physics、SceneKit Physics 或通用刚体求解器取代格斗专用状态机；
- 不允许渲染器成为位置、HP、碰撞或剧情事实的权威；
- 不把所有剧情语义强制翻译成键盘按键。

未来如果需要 MUGEN importer、网络 rollback 或 Metal renderer，它们必须建立在
本文的稳定数据边界之上。

## 3. 参考实现与许可边界

实现时可以直接研究并翻译以下项目中与本设计匹配的小型模块，并在 NOTICE 中保留
必要归属：

- Fighters Paradise，参考提交
  4f67007bfa4448e2e254b69a386b61407360ec3c，MIT。
  主要参考 fixed 60Hz、InputBuffer、CommandMatcher/CommandSynthesizer、
  AABB collision、PushBox、HitDef/Hit resolution、snapshot/replay。
- IKEMEN GO，参考提交
  76dd472f1c3876d64f52232e514bfaef9ada6aad，引擎 MIT。
  主要作为 MUGEN 风格 state/hit/guard/throw/cancel 边界的第二实现参考。
- OpenBOR，参考提交
  787b6770409935137579715febf80cf7a529b748，BSD-style license。
  只借鉴多角色 CHASE/AVOID/WANDER、目标选择与 beat-em-up 行为，不复制整个
  entity runtime。

原则：移植“纯算法和测试”，不移植菜单、SDL、资源格式解析、渲染、音频或
P1/P2 假设。任何翻译代码都必须先写来源注释和等价测试，再做桌面世界改造。

## 4. 最终模块边界

建议目标依赖图：

~~~text
MyPetCore
   ↑
MyPet2D              // geometry, body, physics, surfaces, generic action timeline
   ↑
MyPetCombat          // fighter input, moves, hit/guard/health rules
   ↑
MyPetEngine          // owns runtime and composes Core + 2D + Combat
   ↑
MyPetSimulation
   ↑
MyPetApp
   │
   ├────────────→ MyPetPlatform
   └────────────→ MyPetRender
~~~

### 4.1 MyPetCore

只保存跨平台纯数据：

- EntityID / EntityState / WorldState；
- 旧的 BehaviorRequest、Slot、Relationship、Story facts；
- BodyID、BodyPose、BodySnapshot；
- physics geometry 的纯值类型；
- RenderSnapshot 的纯值数据；
- Runtime clock / event types；
- 不依赖 AppKit、CoreGraphics 的平台对象身份。

### 4.2 MyPet2D

纯 Swift、无 AppKit、可 headless；这是所有桌面实体共享的 2D 游戏底层，
不能依赖具体 combat 规则：

~~~text
Sources/MyPet2D/
  Geometry/
    Vec2.swift
    Rect.swift
    CollisionMask.swift
    Sweep.swift
  Body/
    BodyDefinition.swift
    BodyState.swift
    BodyWorld.swift
    Surface.swift
    Contact.swift
    PhysicsSolver.swift
    Constraint.swift
  Action/
    ActionTimeline.swift
    ActionState.swift
  Replay/
    BodyWorldSnapshot.swift
~~~

普通 walk、jump、window、pointer drag/toss、prop physics 和剧情移动只依赖
MyPet2D。这样以后增加非格斗玩法时，不必引入 Fighter/HitDef 概念。

### 4.3 MyPetCombat

依赖 MyPetCore + MyPet2D，只增加格斗游戏规则：

~~~text
Sources/MyPetCombat/
  Input/
    FighterInput.swift
    InputBuffer.swift
    CommandDefinition.swift
    CommandMatcher.swift
    CommandSynthesizer.swift
  Move/
    MoveDefinition.swift
  Combat/
    CombatantState.swift
    CollisionBoxes.swift
    HitDefinition.swift
    HitResolver.swift
    CombatSession.swift
    CombatEvent.swift
  AI/
    CombatObservation.swift
    CombatPolicy.swift
    UtilityCombatPolicy.swift
  Replay/
    InputTrace.swift
~~~

名字可以在实现时微调，但通用 physics/body 不得重新塞回 Combat，也不得混回
PetController。

### 4.4 MyPetEngine

继续拥有：

- GameRuntime：唯一时序所有者；
- GameKernel：世界事实、行为、claim、关系、剧情；
- StoryDirector / CastRuntime / SemanticPipeline；
- BodyRuntime adapter：GameKernel 与 BodyWorld 的桥；
- ControlRouter：autonomous / manual / authored 的控制源仲裁。

### 4.5 MyPetPlatform

只负责：

- NSScreen / CGWindowList → DesktopSurfaceSnapshot；
- NSEvent / 控制面板按键 → RawInputEvent；
- 鼠标采样 → PointerInputEvent；
- Accessibility 的批准平台动作；
- 不保存 BodyState，不做碰撞，不推进动画。

### 4.6 MyPetRender

只负责：

- RenderBackend 协议；
- CoreAnimationRenderBackend 第一实现；
- RenderAssetProvider；
- RenderSnapshot → 可见像素；
- 音效/视觉特效的表现消费；
- 不写回位置、碰撞、HP、slot、关系。

## 5. 一个基础逻辑帧：60Hz

游戏底层使用固定 60Hz logic frame：

~~~text
1 simulation frame = 1 / 60 second
~~~

不要用整数 16ms 表示一帧。实现可使用整数纳秒累加器或有理数时钟，保证长期无漂移。

### 5.1 保留旧 20Hz 语义时间

现有 GameKernel 大量 durationTicks 按 50ms/tick 编写。迁移时不能把旧 tick 直接解释
为 60Hz frame，否则一分钟会变成 20 秒。

GameRuntime 应拥有一个 60Hz 基础帧计数：

~~~text
simulationFrame: Int64      // 60Hz
semanticTick: Int64         // 每 3 frame 前进一次 = 20Hz
~~~

规则：

- 输入、鼠标、身体、碰撞、战斗每个 simulationFrame 都处理；
- GameKernel / Story / Goal / Scene 的旧时间语义每 3 帧推进一次；
- 新 CombatMove 一律使用 frame 数；
- 旧 durationTicks 保持 50ms 语义，直到单独做版本迁移；
- Render 不推进任何 clock。

### 5.2 主循环顺序

每个 60Hz frame 的固定顺序：

~~~text
1. ingest platform / replay input scheduled for this frame
2. update control authority
3. sample autonomous/manual/script input
4. push FighterInput into per-actor InputBuffer
5. resolve command → desired action
6. advance action state / startup-active-recovery
7. update externally driven surfaces (windows/screens)
8. apply constraints (mouse grab, surface attachment)
9. integrate velocity / gravity
10. solve environment contacts and support surfaces
11. solve PushBox contacts
12. place HitBox/HurtBox/Sensor boxes in world space
13. collect candidate hits / throws / interactions
14. resolve candidates in deterministic batch
15. apply damage, hitstop, hitstun, impulses, knockdown
16. advance downed/get-up/recovery state
17. emit Body/Combat events
18. every third frame: advance legacy semantic GameKernel tick
19. publish immutable BodySnapshot + RenderSnapshot
~~~

任何实现如果把第 14 步改成“遍历到谁就立即修改谁”，会产生 entity 顺序优势，
必须拒绝。

## 6. 坐标系统

继续使用当前桌面世界约定：

- 原点为主屏左上；
- x 向右；
- y 向下；
- actor 的位置为脚底轴点；
- CGWindowList bounds 与 world space 同系；
- 只有最终呈现到 AppKit 时转换 y 坐标。

所有碰撞框、窗口 surface、鼠标、RenderSnapshot 使用同一个 world coordinate。
渲染器禁止再次修改 actor world x/y。

建议 Core 层不要暴露 CGPoint/CGRect；提供简单 Sendable 的 Vec2 / Rect，
Platform/Render 层负责转换。

## 7. 通用 Body 数据模型

不是所有世界实体都是 Fighter，但所有会移动或参与碰撞的实体都可以拥有 Body。

建议最小模型：

~~~text
BodyDefinition
  id
  entityID
  kind: actor | dynamicProp | projectile | staticGeometry | externalSurface
  collisionShape
  collisionCategory / mask
  mass / inverseMass
  gravityScale
  friction
  restitution
  continuousCollision
  maxSpeed

BodyState
  position
  velocity
  acceleration
  facing
  locomotionState
  supportAttachment?
  activeConstraint?
  grounded
  enabled
~~~

### 7.1 Body 类型

actor：
- 可控制的 kinematic/dynamic hybrid；
- 横向移动通常由状态机控制；
- 受击、鼠标抛掷、掉落可以使用冲量；
- 不允许通用 solver 随机旋转角色。

dynamicProp：
- 可受重力、冲量、反弹；
- 可以成为攻击投掷物，但默认接触不造成伤害。

projectile：
- 按 MoveDefinition 驱动；
- 可以有 HitBox；
- 生命周期受 frame/碰撞控制。

staticGeometry：
- 测试或虚拟场景中的固定平台。

externalSurface：
- macOS 窗口/屏幕生成；
- transform 由 Platform snapshot 驱动；
- solver 不能反向移动真实窗口。

## 8. Desktop Surface 与多显示器

保留当前 Screens / WindowWorld 已验证的语义，但把它们投影成纯数据
DesktopSurfaceSnapshot，再由 BodyWorld 消费。

Surface 至少包含：

~~~text
surfaceID
kind: displayFloor | windowTop | windowBottom | synthetic
left / right / y
oneWay
velocity             // 窗口移动时用于相对运动
revision
ownerEntityID?
~~~

必须支持：

- 多显示器负坐标；
- 不同显示器高度；
- 屏幕之间没有真实地面的空隙；
- 等高且允许连接的 floor segment；
- window top / bottom；
- window move/resize revision；
- window minimize/close 后 surface 消失；
- 支撑面消失后 actor 在下一个 frame 进入 airborne；
- 站在移动 surface 上时保持局部横向参数 u，而不是每帧把角色 teleport。

当前 floorBeyond、merged floor 等规则可以转成 DesktopSurfaceBuilder 的纯函数测试。

## 9. 物理求解

### 9.1 角色运动

角色不采用自由刚体“全自动”求解。格斗角色需要可预测控制：

~~~text
velocity += accelerationPerFrame
velocity.y += gravityPerFrame
position += velocity
~~~

当前 PetModel.gravity = 1600pt/s² 在 60Hz 下约等于 0.4444pt/frame²，
可以作为迁移基准，而不是改变手感。

走路/跑步速度从 pt/s 转为 pt/frame，保持现有视觉速度。

### 9.2 环境接触

环境碰撞负责：

- floor/window landing；
- 墙/世界边界；
- dynamic prop bounce；
- 支撑面跟随；
- 高速投掷的 swept AABB / segment crossing。

格斗 hit detection 与环境 collision 不混成一个函数。

### 9.3 PushBox

角色身体占位使用 PushBox：

- 默认站立时不能重叠；
- 双方同时前进时按质量/priority 或对称分离；
- downed、dragged、某些交互可以禁用或改变 PushBox；
- Story 中 hug/high-five/give 等强接触动作允许通过 ActionDefinition 临时声明
  contact policy，而不是在 renderer 里把两个 panel 强行重叠。

### 9.4 HurtBox / HitBox / Sensor

至少区分：

- HurtBox：可以被战斗攻击命中；
- HitBox：攻击区域；
- PushBox：身体占位；
- SensorBox：剧情接近、拿取、窗口交互等无伤害检测。

同一 Rect 算法可以复用，但碰撞结果的语义必须由 box kind 决定。

## 10. Action Timeline：普通动作和格斗动作的共同底座

原有 perform clip 与 CombatMove 不应成为两套播放系统。

统一 ActionTimeline：

~~~text
ActionDefinition
  actionID
  durationFrames
  animationBinding
  locomotionPolicy
  interruptWindows[]
  cancelWindows[]
  collisionFrames[]
  rootMotion?
  endState
~~~

普通动作可以没有 HitBox：

~~~text
greet
think
read
give
receive
perch_window
~~~

格斗 Move 在同一个 timeline 上增加 CombatDefinition：

~~~text
CombatMove
  command
  startupFrames
  activeFrames
  recoveryFrames
  hitDefinitions[]
  guardRules
  cancelRules
  invulnerabilityWindows
  meterCost?
~~~

因此动画、剧情、格斗共享“动作开始/推进/取消/结束”的一个权威状态。

## 11. 格斗碰撞数据

每个动作帧可以声明本地 collision box：

~~~text
CollisionBox
  kind: push | hurt | hit | sensor
  rectLocal
  activeFrameRange
  hitGroup?
  tags[]
~~~

角色朝左时本地 x 关于角色 axis 镜像，y 不变。边缘只接触而没有面积重叠时，
默认不视为命中，以保持 MUGEN 风格 AABB 语义。

### 11.1 HitDefinition

最小字段：

~~~text
HitDefinition
  damage
  chipDamage
  attackHeight: high | low | mid | air | throw
  hitstopAttackerFrames
  hitstopDefenderFrames
  hitstunFrames
  blockstunFrames
  knockback
  launchVelocity?
  knockdown
  hitGroup
  maxHitsPerTarget
  rehitDelayFrames?
  priority
  clashPolicy
~~~

### 11.2 防止逐帧重复命中

每个动作实例生成 moveInstanceID。

命中去重 key 至少是：

~~~text
(attackerID, moveInstanceID, hitGroup, defenderID)
~~~

除非 move 显式声明 rehit/multi-hit，否则持续 3 帧的 HitBox 对一个 defender 只命中一次。

### 11.3 同帧命中

先 collect，再 resolve。

同帧 A 命中 B 且 B 命中 A 时，根据 move priority / clashPolicy 决定 trade、clash
或单方胜出。不能因为 Dictionary/Array 遍历顺序不同而改变结果。

## 12. 战斗状态

建议不要把所有内容塞进一个巨大 enum。至少拆为：

~~~text
LocomotionState
  grounded
  walking
  running
  airborne
  perched
  dragged
  tossed

ActionState
  neutral
  performing(actionID, frame)
  frozen(hitstop)

HealthState
  active
  hitStun
  blockStun
  knockback
  knockdown
  downed
  gettingUp
  recoveryInvulnerable
~~~

因此可以表达：

~~~text
locomotion = airborne
health = knockdown
action = frozen(hitstop)
~~~

而不需要创造 dozens of combinational states。

## 13. HP = 0：倒地和自动恢复

HP 归零不销毁 EntityState。

默认状态流程：

~~~text
HP reaches 0
  ↓
incapacitated
  ↓ if airborne: finish knockback/fall
knockdown landing
  ↓
downed
  ↓ after stable recovery delay
gettingUp
  ↓
restore HP
  ↓
recoveryInvulnerable
  ↓
active
~~~

建议默认参数，仅作为 Gameplay/CombatProfile 默认值：

- maxHP = 1000；
- downedRecoveryDelay = 480 frames（8 秒）；
- requireStableGround = 30 frames；
- getUpDuration = 36 frames（0.6 秒）；
- restoreHP = 30% maxHP；
- recoveryInvulnerability = 120 frames（2 秒）。

规则：

1. downed 期间 AI 不把角色作为普通攻击目标；
2. downed 默认关闭 HurtBox 或使用 downedHitPolicy；
3. 鼠标仍然可以抓取倒地角色；
4. 被抓住、仍 airborne 或支撑面不稳定时，到期也不直接站起；
5. drag/toss 不重置 downed timer；
6. manual control session 不结束，但 downed 时按键不能越过状态限制；
7. get-up 完成才恢复攻击权；
8. KO 可以结束当前 CombatSession，但角色实例继续存在；
9. 剧情可以等待 recovered、走 defeat branch 或让角色 retreat；
10. 不使用 destroyEntity 表达普通格斗失败。

## 14. Fighter Input

最小硬件输入：

~~~text
direction: neutral/up/down/left/right + diagonals
buttons: A/B/C/X/Y/Z
meta: targetCycle / releaseControl
~~~

输入缓存建议保持至少 60 帧。

CommandDefinition 支持：

- forward/back 相对朝向；
- diagonal；
- press / hold / release；
- simultaneous；
- strict adjacency；
- max command time；
- charge hold frames。

例：

~~~text
light = X
dash = F, F
qcf_x = D, DF, F, X
dragon_x = F, D, DF, X
~~~

AI CommandSynthesizer 必须通过同一 CommandMatcher 自验证，不能直接调用
startMove("special") 绕过输入规则。

## 15. 控制权：AI、玩家、剧情

ControlRouter 每个 actor 只有一个 locomotion/combat 输入 authority：

~~~text
ControlAuthority
  autonomous
  manual(sessionID)
  authored(sceneID)
  disabled
~~~

优先规则：

1. Pointer Grab / platform emergency constraint；
2. Manual control；
3. authored non-interruptible action；
4. urgent autonomous reaction；
5. autonomous combat/ambient。

“优先”只决定谁可以提出输入，不代表绕过 Action/Health state。

### 15.1 手动控制

用户从角色操作环选择“接管控制”：

~~~text
select actor
→ create ManualControlSession
→ show small key-capable ControlPanel
→ ControlPanel becomes key
→ KeyboardInputAdapter emits RawInput
→ ControlRouter binds actor
~~~

默认键位：

~~~text
Arrow Left / Right   move / back
Arrow Up             jump
Arrow Down           crouch
Z X C                three attack buttons
A S D                three attack buttons
Tab                  cycle combat target
Esc                  release control
~~~

键位必须配置化。

第一版不要要求 macOS Input Monitoring 权限。控制面板作为 key window 接收按键。
未来可增加可选 global input adapter，但它只能生成相同 RawInput，不得另写逻辑。

窗口 resign key、应用停用、控制会话结束时必须发送 all-buttons-up，防止 sticky input。

### 15.2 自主战斗

UtilityCombatPolicy 第一版只选择战术：

- approach；
- retreat；
- jump；
- guard；
- dodge；
- light/heavy attack；
- throw；
- special command。

它输出 CombatDecision，再由 CommandSynthesizer 产生 FighterInput frames。

未来 NanoJev、Core ML 或其他策略模型只替换 CombatPolicy，不替换 BodyWorld。

## 16. 剧情兼容

StoryDirector、StoryPack、Relationship、Slot、StoryFact 保持原有领域职责。

关键规则：

### 16.1 Presentation action 与 real combat 分开

旧剧情的 attack / argue / challenge 不能因为底层升级就自动扣 HP。

ActionExecution 明确区分：

~~~text
presentation(actionIntent)
combat(moveID, targetID, sessionID)
interaction(interactionID, target/slot)
locomotion(destination/intent)
~~~

presentation 可以播放攻击姿态但没有 damaging HitBox。

只有 combat execution 才能产生 HitDefinition 和 HP 变化。

### 16.2 剧情移动

剧情不直接设置 x/y。

move_to / approach 必须变成 BodyWorld locomotion goal：

~~~text
Story/Scene
→ BodyCommand(goal)
→ BodyWorld
→ reached / blocked / interrupted
→ BodyResult
→ GameKernel
~~~

### 16.3 剧情战斗

剧情需要真实战斗时：

~~~text
StoryBeat(start_combat)
→ validate combat capability
→ create CombatSession
→ assign participants / teams / victory condition
→ AI/manual controllers run through normal fighter input
→ BodyWorld emits combat outcome
→ GameKernel commits result
→ StoryDirector chooses next branch
~~~

剧情不能直接声明“某人胜利”然后跳过战斗，除非 beat 明确是 presentation-only。

### 16.4 抢占

用户抓取、manual takeover、窗口销毁等继续使用现有高优先级抢占。

被抢占的 Story behavior 必须得到 cancelled/failed/suspended 的确定结果；不能在视觉
动作未发生时提交关系效果或 slot 成功。

## 17. 鼠标、拖拽和抛掷

当前 Pointer Reflex 与鼠标 P0 交互继续保留，但接入 BodyWorld。

### 17.1 Grab

mouseDown 命中 actor：

- cancel interruptible current action；
- disable damaging HitBoxes；
- create PointerGrabConstraint；
- locomotion = dragged；
- 保留 HealthState，例如 downed 不被清掉。

### 17.2 Drag

每帧 constraint 根据 raw cursor sample 更新目标位置，并估算 filtered release velocity。

### 17.3 Release

click：
- 继续当前点击反射；
- 不产生大速度。

drag release：
- 删除 grab constraint；
- velocity 使用采样结果；
- locomotion = tossed/airborne；
- 进入同一 gravity / collision / surface landing。

### 17.4 Perched window pull

原有“拖动栖息角色拉真实窗口”保留为显式 PlatformAction：

- BodyWorld 只表达角色仍附着于 window surface；
- WindowPuller 在获授权时移动窗口；
- 下一份 DesktopSurfaceSnapshot 反馈真实新位置；
- 禁止 physics solver 直接写 AX window position。

## 18. Render 完全分离

这是本迁移的硬约束。

### 18.1 RenderSnapshot

GameRuntime 每个 logic frame 发布不可变快照：

~~~text
RenderSnapshot
  simulationFrame
  entities[]
    entityID
    worldTransform
    facing
    visualState
    animationID
    animationTime/frame
    displaySize
    zOrderHint
    attachments[]
  effects[]
  debugGeometry?   // optional
~~~

RenderSnapshot 不包含可变 WorldState 引用。

### 18.2 RenderBackend

定义稳定后端协议，概念接口：

~~~text
prepare(resources)
resize(screenTopology)
render(snapshot, interpolation)
setDebugOptions(...)
shutdown()
~~~

RenderBackend 只读取 snapshot。

任何后端都不得：

- clamp actor world position；
- 为避免角色重叠而改 x/y；
- 决定角色是否命中；
- 完成 BehaviorRequest；
- 修改 slot/relationship/HP；
- 根据动画结束直接写 Kernel。

### 18.3 PresentationHost 与 Renderer 分开

macOS 透明窗口是“呈现宿主”，不是 renderer 本身。

建议区分：

~~~text
DesktopPresentationHost
  manages NSPanel / per-screen surfaces / hit routing

RenderBackend
  turns RenderSnapshot into pixels/layers
~~~

这样未来可以：

第一版：
- 每 actor 透明 nonactivating NSPanel；
- CALayer sprite/effect composition。

后续：
- 每 screen 一个透明 overlay NSPanel；
- CAMetalLayer / Metal 批量绘制所有 actors；
- 自定义 hit-test router。

GameRuntime 完全不用改。

## 19. 第一版渲染后端：Core Animation

第一版选择 AppKit + Core Animation：

- NSPanel 继续承担桌面透明窗口、level、mouse routing；
- CALayer 承担 sprite、prop、effect compositing；
- CGImage/ImageIO 解码 WebP；
- CATransaction 禁用隐式动画；
- 只更新发生变化的 layer contents / transform；
- 资源由 RenderAssetProvider 缓存；
- renderer 使用 snapshot position，不做布局修正。

理由：

1. 是 macOS 原生 GPU compositing 路径；
2. 与现有透明桌宠窗口集成成本最低；
3. 普通几十个 sprite 的 CPU/GPU 开销足够低；
4. 不阻塞未来 Metal；
5. 本次重点是正确分离 world/render，而不是同时重写全部像素管线。

### 19.1 必须删除的渲染权威

当前类似 SpatialSafety.placeActor、layoutCoordinator 二次修改最终 actor frame 的行为，
不能继续作为 renderer 私有事实。

迁移方式：

- 安全区域变成 BodyWorld/PlacementPlanner 的目标或约束；
- Cast 排位变成 world position；
- renderer 只做 world → AppKit coordinate transform；
- 纯视觉 transition 允许 opacity/scale/visual offset，但不能改变 physics anchor；
- 如果需要视觉 anticipation/squash，单独使用 visualOffset，碰撞仍以 world body 为准。

### 19.2 为 Metal 预留

未来 Metal 后端应只实现相同 RenderBackend：

~~~text
RenderSnapshot
→ SpriteBatch
→ TextureAtlas
→ CAMetalLayer
~~~

需要预留：

- stable texture/resource ID；
- atlas-friendly UV metadata；
- per-instance transform/facing/opacity；
- effect instance data；
- frame interpolation；
- per-screen render target；
- debug hitbox overlay。

不要让 Core Animation 类型进入 RenderSnapshot。

## 20. 动画与逻辑帧分离

视觉素材帧率不等于 combat frame。

例如 8 张图 @ 4fps 也可以对应 24 个 60Hz combat frames。

AnimationBinding 必须定义：

~~~text
animationID
visualFPS
playback
logicFrame → visualFrame mapping
~~~

HitBox、cancel、damage 永远绑定 logic frame，不绑定“第几张 WebP”。

## 21. 模拟器必须运行同一个 BodyWorld

当前 headless BodyRuntime 的“到时间就 completed、move_to 直接把 pose.x 设置到目标”
只可作为迁移前行为，不能作为新底层的最终实现。

目标：

~~~text
Production:
MacPlatformAdapter
    ↓
DesktopSurfaceSnapshot / RawInput
    ↓
GameRuntime + BodyWorld + CombatRuntime
    ↓
RenderSnapshot
    ↓
CoreAnimationRenderer

Simulation:
VirtualDesktopAdapter
    ↓
DesktopSurfaceSnapshot / RawInput
    ↓
SAME GameRuntime + SAME BodyWorld + SAME CombatRuntime
    ↓
RenderSnapshot / Trace
~~~

模拟器只替换输入和平台事实来源。

必须支持模拟：

- 多显示器；
- window create/move/resize/minimize/close；
- keyboard press/release；
- pointer move/down/drag/up；
- manual takeover/release；
- AI combat；
- prop collision；
- surface fall；
- KO/downed/get-up；
- Story + combat 混合。

## 22. Record / Replay

Replay 至少记录：

~~~text
engineVersion
contentVersion/fingerprint
seed
initialSnapshot
per-frame platform events
per-frame keyboard input
per-frame pointer samples
surface revisions
manual control changes
external AI decisions (if nondeterministic)
~~~

不要求录制 Render output。

Checkpoint 至少包含：

- GameKernel snapshot；
- BodyWorld bodies；
- surfaces/revisions；
- InputBuffer；
- active Action/Move frame；
- HP/HealthState；
- hit dedupe state；
- CombatSession；
- downed/get-up timers；
- RNG state；
- attachments/constraints；
- semantic tick alignment。

同版本、同内容 fingerprint、同初始 snapshot、同 input trace 必须产生相同 world digest。

## 23. CombatSession

战斗是世界中的一个可选会话，不是应用全局模式。

~~~text
CombatSession
  sessionID
  participants
  teamID per participant
  target policy
  rules
  victoryCondition
  state
~~~

多个无关角色可以继续聊天/看窗口，而另外两个角色在战斗。

`participants` 默认只包含显式参战者，但不是只能在 session 创建时写入的固定数组。ruleset 可以
声明 collateral policy：未参战中立角色不进入 CPU 合法目标集合，但真实 hit/projectile 若误伤其
HurtBox，CombatEscalationSystem 可在当前 collision batch 完成后的下一逻辑帧，以稳定 session
command 将其加入为 incidental combatant，并记录责任者和临时 target policy。正式竞技 ruleset
默认关闭该能力；动态加入、仇恨和撤离必须进入 checkpoint/replay。

默认规则是 non-lethal sparring：

- KO 不 destroy entity；
- 一方首次进入 downed 可以结束该 session；
- session 结束后角色仍走自己的 downed/get-up 恢复；
- Story 可以等待 recovered 或直接进入下一 beat。

free-for-all、team battle、自由换人和中立 NPC 动态参战都要求数据模型禁止 P1/P2 固定字段。

## 24. Determinism 规则

为了支持 Harness 和未来训练：

1. actor/body 遍历按稳定 EntityID 排序；
2. collision candidates 排序后 batch resolve；
3. RNG 全部来自显式 seed；
4. 不在 Core 使用 Date、systemUptime、Double.random；
5. window snapshot 是输入，不在 BodyWorld 内直接查询 macOS；
6. 浮点边界使用统一 epsilon；
7. replay 中不重新调用不确定模型，保存其决定；
8. renderer 完全不反馈 gameplay；
9. 所有 timeout 用 logic frame/semantic tick，不用 wall clock；
10. async adapter 返回结果必须带 epoch/fingerprint。

## 25. 迁移当前代码的映射

### 25.1 PetModel

现有能力迁移到：

| PetModel 责任 | 新位置 |
|---|---|
| x/y/vx/vy/facing | BodyState |
| gravity/airborne/landing | PhysicsSolver |
| grounded/perched | LocomotionState + SurfaceAttachment |
| walk/hurry | LocomotionController |
| hop/leapTo | Action/Locomotion command |
| drag/toss | PointerGrabConstraint + PhysicsSolver |
| floor/window lookup | DesktopSurfaceSnapshot |
| window follow | SurfaceAttachment |
| sleep | ordinary Action/Health-independent state |
| clampToVirtual | world boundary constraint |

迁移完成后 PetModel 删除或只保留短期 compatibility facade，不得继续拥有第二份位置。

### 25.2 PetBodyDriver

迁移为 BodyCommand/Action adapter：

- moveTo → locomotion goal；
- perform → ActionDefinition；
- interact(window) → interaction plan；
- sleep → ordinary action/state；
- wait → stop desired locomotion。

不再自己维护独立 clock。

### 25.3 BodyRuntime

继续是 Kernel bridge，但 headless/external 不再代表两套“身体实现”。

最终：

- BodyWorld 永远是同一实现；
- headless = 没有 Renderer/Platform side effects；
- external = 有 macOS Adapter；
- BodyResult 根据真实 goal/action outcome 返回，而不是按 duration 直接完成。

### 25.4 PetController

保留为 App 层角色协调器：

- brain/context；
- menu/action ring；
- speech；
- platform presentation lifecycle；
- submit semantic intent；
- 不拥有物理 position。

### 25.5 ActorPresentation

改成 RenderBackend consumer：

- 不再通过 layoutCoordinator 改 world frame；
- 不再决定动作成功；
- 可以选择 visual clip、音轨和纯视觉 transition；
- world anchor 永远来自 RenderSnapshot。

## 26. 建议实现顺序

实现者应按以下顺序工作，禁止先做 UI 再补规则：

1. 建 MyPet2D target 与纯数据 Vec2/Rect，再建依赖它的 MyPetCombat target。
2. 在 MyPet2D 翻译并测试 AABB place/mirror/overlap。
3. 在 MyPetCombat 翻译 InputState/InputBuffer/CommandMatcher/CommandSynthesizer。
4. 建 60Hz RuntimeFrameClock 与 deterministic accumulator。
5. 建 BodyDefinition/BodyState/BodyWorld。
6. 把 display floor/window surface 转成纯数据 snapshot。
7. 迁移 walk/gravity/jump/landing。
8. 迁移 multi-display/floor gap/window attachment。
9. 迁移 pointer grab/toss。
10. 加 PushBox。
11. 建 ActionTimeline，先跑 idle/walk/jump。
12. 接普通 perform action。
13. 建 HurtBox/HitBox/HitDefinition/HitResolver。
14. 建 hitstop/hitstun/blockstun/knockback。
15. 建 knockdown/downed/get-up。
16. 建 CombatSession。
17. 建 FighterInput manual controller。
18. 建 UtilityCombatPolicy + CommandSynthesizer。
19. 改 Story/Scene 的 move/perform bridge。
20. 改 Simulation 使用真实 BodyWorld。
21. 建 RenderSnapshot。
22. 提取 RenderBackend / PresentationHost。
23. 改 CoreAnimation renderer 只读 snapshot。
24. 把 SpatialSafety/Layout 的位置修正下沉为 world planner。
25. 删除 PetModel 的权威状态。
26. 完成 record/replay checkpoint。
27. 跑完整兼容矩阵。
28. 最后才允许删除 compatibility facade。

## 27. 单元测试要求

### 27.1 Geometry

- facing mirror；
- edge touching not hit；
- normalized reversed corners；
- swept landing；
- high-speed toss 不穿 window/floor。

### 27.2 Physics

- 60Hz gravity 基准；
- walk/run 速度；
- jump apex/landing；
- multi-screen step；
- screen gap fall；
- moving window follow；
- closed window drop；
- prop bounce/friction。

### 27.3 Input

- press/hold/release；
- diagonal；
- simultaneous；
- charge；
- strict sequence；
- facing reverse；
- synthesized command 必须被 matcher 识别。

### 27.4 Combat

- startup 不命中；
- active 命中；
- recovery 不能立即重出；
- one move one hit；
- multi-hit；
- trade/clash；
- guard/high/low；
- hitstop；
- hitstun；
- knockback；
- knockdown；
- HP=0 → downed；
- downed timer；
- dragged while downed；
- get-up + HP restore + invulnerability。

### 27.5 Story compatibility

至少回归：

- enter/exit；
- window perch；
- prop take/give/receive；
- social talk/hug/high-five；
- mech attach；
- authored story；
- story preemption；
- relationship effect only on success；
- presentation attack 不扣 HP；
- real combat beat 等待 CombatOutcome。

### 27.6 Manual control

- take over one actor only；
- key down/up；
- focus lost clears inputs；
- Esc release；
- Tab target；
- manual cannot bypass hitstun/downed；
- release returns to autonomous；
- pointer grab overrides manual then returns control。

### 27.7 Render separation

测试必须能替换 NullRenderBackend：

~~~text
run 1000 frames with NullRenderer
world digest == run 1000 frames with CoreAnimation-free simulation
~~~

RenderSnapshot 不可影响 world digest。

## 28. Harness / 集成验收矩阵

Logic 必须覆盖：

1. 单角色旧桌宠闲逛；
2. 多角色同屏；
3. 多显示器跨屏；
4. 窗口移动/关闭；
5. pointer attention；
6. click；
7. drag/toss；
8. prop interaction；
9. Story episode；
10. AI vs AI；
11. manual vs AI；
12. manual takeover during story；
13. grab actor during attack；
14. knockback off window；
15. KO/downed；
16. downed 被拖走；
17. surface 消失 during downed；
18. get-up；
19. replay；
20. long-run no invariant violation。

Platform 另验：

- 真实 NSScreen 坐标；
- Retina scale；
- 透明 NSPanel；
- 鼠标 hit routing；
- ControlPanel keyboard；
- window move；
- WebP；
- Core Animation CPU/GPU/内存；
- 40/60/120Hz 显示器；
- 多屏不同 refresh rate。

## 29. 性能预算

第一版目标不是极限优化，但架构必须可扩展。

建议基准：

- BodyWorld 64 actors + 128 dynamic props，60Hz；
- Broadphase 可以先用稳定 sweep/grid；禁止 O(N²) 无上限扩散；
- collision boxes 只处理 active/nearby bodies；
- RenderAssetProvider 解码后缓存 CGImage；
- Core Animation 只更新 dirty entity；
- renderer 不能触发同步磁盘 IO；
- simulation frame p95 明显低于 16.67ms；
- 性能报告区分 simulation、render、platform polling。

如果未来大量角色/粒子导致 Core Animation 成为瓶颈，直接替换 Metal backend，
而不是修改 BodyWorld。

## 30. 资源契约

公开运行时只定义格式，不携带私有角色素材。

角色包可选增加 combat profile：

~~~text
combat/
  profile.json
  moves.json
~~~

或者等价地纳入现有 manifest versioned schema。最终选择必须满足：

- versioned；
- stable move ID；
- command；
- timeline frames；
- collision boxes；
- damage/stun/knockback；
- animation binding；
- downed/get-up settings；
- capability gate；
- unknown field/unsupported version 可诊断。

无 combat profile 的旧角色包继续支持原玩法；不能因为升级 runtime 无法加载。

拥有 combat capability 但缺 combat profile 时：
- 可参与 presentation-only conflict；
- 不得被报告为完整 real-combat ready。

## 31. 兼容验收：旧功能一项都不能靠渲染伪造

迁移 PR 的完成定义不是“能打起来”，而是以下全部满足：

- GameKernel/StoryDirector 原有剧情继续通过；
- Pointer Reflex 继续通过；
- click/drag/toss 继续通过；
- multi-screen 继续通过；
- window perch/follow/drop 继续通过；
- props/slots/attachments 继续通过；
- manual control 可随时接管一个 actor；
- AI 与 manual 共用 command path；
- combat 命中由真实 box/contact 产生；
- HP=0 使用 downed/get-up；
- Simulator 使用相同 BodyWorld；
- replay 可复现；
- renderer 不拥有 gameplay position；
- CoreAnimation backend 可以被 NullRenderer 替换而 Logic Verdict 不变。

任何一项未满足，都不能删除旧 PetModel compatibility path。

## 32. 完成后的架构不变量

实现完成后，代码 review 应能用以下问题快速判断设计是否被破坏：

1. “角色现在在哪里？”只能从 BodyWorld/World projection 得到一个答案。
2. “这一拳是否命中？”只能由 Combat collision/resolution 得到答案。
3. “这个剧情动作是否成功？”只能由 BodyResult/GameKernel 得到答案。
4. “为什么屏幕上画在这里？”Renderer 必须能指向 RenderSnapshot，而不是自己的布局状态。
5. “模拟器为什么这样移动？”必须能走到与生产相同的 BodyWorld 代码。
6. “人工控制为什么能出这个招？”必须能追到 InputBuffer/CommandMatcher。
7. “AI 为什么能出这个招？”也必须走同一个 InputBuffer/CommandMatcher。
8. “HP 为零为什么角色还在？”因为 HealthState=downed，不是 Entity destroyed。
9. “以后换 Metal 要改哪里？”只改 MyPetRender/PresentationHost，不改 Core/Combat/Story。
10. “以后导入 MUGEN 角色要改哪里？”新增 importer 把外部格式编译成 Action/Move/Collision 数据，不改 runtime。

满足这十条，说明底层真正从桌宠专用运动逻辑升级成了可承载桌面剧情与格斗游戏的
通用 2D runtime。
