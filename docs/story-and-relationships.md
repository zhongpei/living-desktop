# 多角色、关系与屏幕剧情

> 状态：角色组、CastPack、关系图、剧情节拍和入/出场生命周期的统一边界，
> 2026-09-21。
>
> 玩法总模型见 [gameplay-requirements.md](gameplay-requirements.md)；动作语义与
> 素材覆盖见 [action-foundation.md](action-foundation.md)；空间事实见
> [scene-graph.md](scene-graph.md)。

## 1. 领域分层

多角色玩法同时存在五种不同事实，不能合并成一个“大角色状态”：

| 层 | 回答的问题 | 典型数据 |
|---|---|---|
| 角色定义 | 这个角色是什么 | 身份、人格、身体类型、动作能力、entry/exit profile |
| 角色实例 | 这次出现的是谁 | instanceID、根节点、生命周期、当前占用 |
| SceneGraph | 它在空间哪里、跟随谁 | 父子、局部变换、插槽、空间挂接 |
| RelationshipGraph | 它和别人是什么关系 | 队友、竞争、保护、驾驶、归属 |
| StoryFacts | 最近发生了什么 | 刚刚争吵、等待启动、剧情被打断 |

空间挂接不等于所有权，所有权不等于社会关系，剧情事实也不应成为渲染层变量。

## 2. 角色组与剧组预制方案

目录层级固定为：

~~~text
角色分类
    ↓
角色组
    ↓
CastPack 剧组预制方案
    ↓
角色成员 / 机甲 / 道具 / 舞台 / 剧情
~~~

- 角色分类用于发现和筛选；
- 角色组用于选择、随机、邀请和轮换；
- CastPack 定义一套可共同运行的成员、关系、舞台、道具和故事；
- 角色成员引用稳定角色或机甲 ID，不以显示名称作为主键；
- 单角色也必须能被目录收编，即使没有关系剧情；
- CastPack 不自动赋予成员专属动作，能力必须由角色目录和素材覆盖共同决定。

菜单不能在 Swift 中硬编码角色名、作品分类或可玩剧组。旧分类语义必须迁移为
categoryID；真正的可玩角色组和 CastPack 分开保存。

## 3. 生命周期与出入场

每个能够被剧情邀请、自动轮换或加入屏幕场景的成员都必须有：

~~~text
enter_scene    加入当前舞台、被召唤或从场外进入
exit_scene     离开当前舞台、被送走或返回场外
~~~

这两个语义是 StoryDirector 和 SceneRunner 的生命周期接口，不是角色操作环里的
普通按钮。表现由角色身份、舞台和 entry/exit profile 决定：

| 成员类型 | 入场风格 | 出场风格 |
|---|---|---|
| 普通人 | 从房间、门后或屏幕边缘走出 | 返回房间、关门或走出屏幕 |
| 仙人/神话角色 | 腾云、降落、召唤显形 | 升云、化云或传送离开 |
| 幽灵/能量体 | 渐显、穿过边界 | 渐隐、消散、穿墙 |
| 机甲 | 启动、展开、落位 | 关机、收拢、退场 |

没有专属素材时可以按候选链降级到通用进入/离开表现，但必须记录 fallback，
不能把逻辑成员存在写成专属视觉已完成。

入场流程：

~~~text
select member
    → validate cast/scene/slot
    → claim lifecycle resources
    → enter_scene performance
    → attach root / publish presence
~~~

出场流程：

~~~text
request exit
    → stop new claims
    → resolve or cancel active beat
    → exit_scene performance
    → release slots/resources
    → remove root / publish absence
~~~

表现层不能在中止回调里直接摘除所有权。释放必须由 GameKernel 在下一个事件边界
提交，避免旧节拍和新节拍同时认为成员仍然占用同一位置。

## 4. RelationshipGraph

RelationshipGraph 是稳定关系的有向图。边至少携带：

- source 和 target 的稳定实体 ID；
- relationshipKind，如 teammate、rival、protect、pilot；
- strength、trust、tension 或 readiness 等状态；
- 哪些 scene/beat 可以使用这条关系；
- 由声明式效果改变状态的边界。

关系图不保存：

- 当前空间位置、插槽占用和父子节点；
- 一次动作的播放进度；
- 单次剧情的临时 claim；
- 短时火花、烟雾或裂痕。

关系状态只能由 GameKernel 提交声明式效果改变。决策脑可以提出冲突、安慰或保
护目标，不能直接写入 trust/tension。

## 5. StoryFacts 与分支

StoryFacts 是有限生命周期的剧情事实，例如：

- 成员已经入场；
- 某次道具转交已成功；
- 角色刚刚争执；
- 机甲等待启动；
- 上一段剧情被用户抢占；
- 某个分支已经选择。

事实必须有来源、时间/回合标识和清理条件。它不是长期人格，也不是动画播放状态。
StoryDirector 只读取它来选择合法节拍。

## 6. StoryDirector、StoryEpisode 与 StoryBeat

StoryEpisode 是一段可中断的屏幕剧情；StoryBeat 是其中一个可观察变化。一个
StoryBeat 至少声明：

- 参与者、目标实体和前置关系；
- 入场/出场要求；
- 需要的普通基础动作或能力包；
- 道具、机甲和交互槽位；
- 台词、等待、可抢占边界；
- 成功/取消/中止结果；
- 关系效果、StoryFacts 和下一节拍。

推荐生命周期：

~~~text
episode prepare
    → member enter_scene
    → claim relation/prop/slot
    → perform beat
    → commit effects/facts
    → release
    → member exit_scene or continue
~~~

StoryDirector 不直接播放文件、不创建任意角色、不改关系值、不清空槽位。它只
把候选节拍提交给 GameKernel；GameKernel 再根据当前世界和动作覆盖选择 exact、
fallback 或 missing 路径。

默认每段剧情有有限 tick/时间预算，用户直接互动始终可以抢占。后台内容和教师脑
结果不能锁住剧情。

## 7. StoryHandoff 与递物

StoryHandoff 是显式的释放—接收边界。只有以下事实全部匹配时才能产生
StoryHandoffEvent：

- 释放节拍和接收节拍属于同一剧情代次；
- prop、双方角色和目标 slot 全部匹配；
- 释放方已经提交所有权转移；
- 接收方仍然在场且 slot 可用。

AppKit 只播放共享投影几何的短递物插值，不能在表现层改变 Kernel 所有权。剧情
中止后，已经由释放节拍发出的 handoff event 仍保留到消费完成。

## 8. 首批剧情能力

| 剧情能力 | 需要的世界事实 | 表现与降级 |
|---|---|---|
| 邀请/轮换 | 角色目录、空闲 root、生命周期资源 | exact entry/exit 或通用 fallback |
| 问候 | 双方在场、关系允许 | greet_other 或 greet/listen/talk |
| 安慰/争执 | 社会关系和当前剧情事实 | 专属 social 能力或基础表达 |
| 递物 | prop、双方 hand/slot、释放/接收节拍 | give/receive 或几何道具 |
| 机甲启动 | mech、pilot、cockpit slot | 专属 mech 能力或确定性几何 fallback |
| 窗口剧情 | window slot、目标窗口和安全框 | window 能力或 look/point |
| 嘲讽/战斗 | combat 关系、目标、接触框和恢复路径 | taunt/attack/defend 或 tease/talk/surprised |

## 9. 当前状态与验收

当前运行时已有多角色 Cast、关系/剧情配置、生命周期清理和 StoryHandoff 的
headless 回放边界；实际专属动作和入/出场视觉完整度仍以
[asset-audit.md](asset-audit.md) 为准。

多角色验收必须分开报告：

- Logic：邀请、入场、claim、节拍、释放、转交、退出和抢占是否正确；
- Content：每个成员普通 24+6、enter/exit 和能力包的 exact/fallback/missing；
- Platform：真实 AppKit 多根节点、层级、遮挡、帧序和最终观感。

Cast 中出现一个成员，不能证明它有专属动作；有基础 idle/walk，也不能证明入场、
出场、道具、社交或机甲素材已经完成。
