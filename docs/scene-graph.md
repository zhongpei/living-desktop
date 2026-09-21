# 空间场景图与世界附着

> 状态：多角色、窗口、道具和机甲共用空间事实的统一说明，2026-09-21。
>
> 玩法配方见 [gameplay-requirements.md](gameplay-requirements.md)，关系和剧情见
> [story-and-relationships.md](story-and-relationships.md)，动作与入/出场素材见
> [action-foundation.md](action-foundation.md)。

## 1. 场景图只表达空间

SceneGraph 是从场景根开始的父子层级，回答“谁跟随谁、节点在哪里”。它不承载：

- 角色之间的社会关系；
- 道具的长期所有权；
- 当前行为意图；
- 剧情分支和关系数值；
- 视觉特效的长期状态。

这些事实分别属于 RelationshipGraph、WorldState、StoryFacts 和 EffectState。

~~~text
SceneRoot
├── WindowNode
│   └── WindowSlot / SurfaceSlot
├── CharacterRoot
│   └── HandSlot / SeatSlot / CockpitSlot
├── MechRoot
└── PropRoot
~~~

每个角色实例、机甲和道具都有稳定的独立根节点。多角色不能共享隐含的 x/y，
也不能因为一个角色离场而重建整棵图。

## 2. 节点与变换

一个 SceneNode 至少有：

- nodeID 和 entityID；
- parentID；
- local position、scale、rotation；
- world transform 的派生值；
- children；
- 可选的 geometry bounds、safe frame 和 anchor。

父节点变化默认保持世界变换。只有明确的吸附、放置、进入插槽或退出插槽操作，
才会根据新父节点重新计算局部变换。

角色的安全框、窗口边界、舞台基线和插槽锚点都必须使用同一坐标约定。安全框是
空间占用和素材 QA 的共同输入，不是渲染层的私有修正。

## 3. 插槽与空间挂接

插槽是挂在角色、窗口、家具或机甲下的命名空间节点，例如：

~~~text
hand
seat
tabletop
window_edge
cockpit
~~~

一个插槽默认只有一个直接占用者。挂接的最小事实是：

~~~text
SpatialAttachment
    childEntityID
    parentEntityID
    slotID
    transformVersion
    owner / claim metadata
~~~

空间挂接只表示跟随关系，不自动表示所有权、赠送、驾驶或社会关系。道具从手到
桌面、从释放方到接收方时，必须由 Kernel 先提交所有权/claim 变化，再更新父子
关系。

## 4. 槽位生命周期

交互槽位有明确生命周期：

~~~text
free → claimed → occupied → free
              ↘ disabled
~~~

- free：可以被查询；
- claimed：某个行为或剧情暂时预留；
- occupied：实体已正式附着；
- disabled：窗口、舞台、驾驶舱或道具不可用。

槽位引用包含 entityID、slotID、几何/可用性版本。窗口移动、缩放、销毁或槽位
禁用需要更新版本；普通窗口内容变化不应无故使槽位失效。

窗口停留使用统一语义 perch_window，并由角色的 windowPerchProfile 选择空间
路径：direct_perch、climb_perch、swing_perch 或 lean_window。最终姿态可以是
sit，也可以是 lean_sill；SceneGraph 记录的是窗口 slot 和变换，不把“坐”误认为
所有角色都使用同一 clip。

行为资源 claim（body、locomotion、manipulator、speech）与世界交互槽位 claim
分开。角色可以占用 body 而不占窗口，也不能用动画完成回调代替 slot release。

## 5. 入场与出场

场景图把角色生命周期作为正式边界，而不是把角色瞬移进根节点：

~~~text
select / invite
    → validate root and target surface
    → claim lifecycle resources
    → enter_scene performance
    → attach CharacterRoot
    → publish presence
~~~

~~~text
request exit
    → reject new claims
    → resolve or abort active beat
    → exit_scene performance
    → release slots/resources
    → detach CharacterRoot
    → publish absence
~~~

统一语义是 enter_scene / exit_scene，具体表现由角色和舞台选择：

- 普通人可以从房间或门后走出，再回到房间；
- 仙人可以腾云驾雾入场、化云出场；
- 幽灵可以显现、消散；
- 机甲可以启动、展开、收拢。

缺少专属素材时，场景图仍可按候选链完成生命周期，但 Content Verdict 必须记为
fallback。表现层不能因素材缺失直接删除节点，也不能把 fallback 误报为专属演出。

## 6. 多角色与共享安全框

每个角色根节点独立参与布局。CastProjection 只把真正加载成功的视觉包纳入横向
安全框；逻辑成员可以留在剧情和报告中，但不应制造虚假的视觉占位。

布局必须处理：

- 多根节点的排序和遮挡；
- 角色与窗口边界的安全间隔；
- 角色/角色、角色/道具和角色/机甲的接触框；
- 缺少专属素材时的几何 fallback；
- 离场摘除根节点、Cast 停止清空并复用 SceneGraph。

任何空间附着环都必须在 InvariantChecker 中报告。不能用投影递归保护把坏快照
悄悄变成看似正常的布局。

## 7. 关系与剧情的连接点

SceneGraph 与 RelationshipGraph 通过稳定 entityID 关联，但不共享存储：

- “A 跟随 B”若是空间事实，写 SpatialAttachment；
- “A 信任 B”写 RelationshipGraph；
- “A 刚把道具递给 B”写 StoryFacts 和所有权转移；
- “A 正在驾驶机甲”写 pilot/cockpit claim 与结构关系；
- “A 头顶有火花”写 EffectState。

StoryDirector 可以要求某个空间条件，不能直接改父节点。SceneRunner 可以申请
槽位，不能直接改关系值。表现层可以读取投影，不能反向写入上述事实。

## 8. StoryHandoff 与交互边界

递物、接收和机甲附着都采用显式释放—接收协议：

1. 释放方持有 prop 和目标 slot；
2. 释放节拍在 Kernel 边界提交转移；
3. 生成匹配的 StoryHandoffEvent；
4. 接收方在同一剧情代次确认 slot；
5. AppKit 播放短插值并完成新的 SpatialAttachment。

如果角色、道具、槽位或代次不匹配，事件不进入表现层。已经发出的事件不会因为
后续剧情 abort 被丢弃，直到消费完成。

## 9. 验收清单

### Logic

- 父子、插槽、transform version 和槽位生命周期一致；
- 入场/出场不会泄漏 claim 或遗留根节点；
- 中止和抢占不会由表现层清空世界事实；
- 多角色共享同一内核和同一 SceneGraph；
- 空间附着环可被 InvariantChecker 报告。

### Content

- 角色入/出场的专属表现和 fallback 清楚分开；
- 角色/窗口/道具/机甲的安全框与锚点来自可审计数据；
- 几何 fallback 不冒充正式视觉素材；
- ActionCatalog 的语义动作与 asset-audit 覆盖表一致。

### Platform

- 真实 AppKit 多根节点、层级、遮挡和动画观感；
- 窗口移动/缩放/关闭后的槽位版本和布局；
- WebP 帧序、锚点、透明度和长时间运行。

纯数据 Harness 的通过只覆盖 Logic，不替代后两项。
