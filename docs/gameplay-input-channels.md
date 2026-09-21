# 玩法输入与三通道交互方案

> 状态：输入路由和 headless 运行时边界，2026-09-21。
>
> 玩法总需求见 [gameplay-requirements.md](gameplay-requirements.md)。角色动作和
> 入场/出场不是本文件的清单，统一见 [action-foundation.md](action-foundation.md)。

## 1. 目标与边界

桌宠需要同时满足三件事：

1. 用户直接操作时立即回应；
2. 前台窗口变化时马上有反应；
3. 读取到聊天、编码或浏览器内容后，本地大脑可以生成更有内容的短回合。

这三件事共享一个事件边界，但不共享一条等待链路。抢占必须独立、快速反应由
本地脑完成、内容读取是可关闭的异步输入插件。

输入插件只提供观察，不能直接移动、表演、说话、启动剧情、修改关系或写入
WorldState。所有输入都先成为事件，再由 GameKernel 在 tick 边界消费。

## 2. 总体模型

~~~text
窗口/鼠标/用户事件 ─────→ 抢占通道 ─────→ P0/P1 BehaviorRequest
       │                       │
       └─窗口标题/活动────────→ 快速反应 ───→ 本地 Goal/Scene/Needle
                                  ↑
AX/OCR/聊天/浏览器/编码插件 ────→ 内容通道 ───→ ContentObservation
~~~

三通道是路由和延迟边界，不是三层大脑。高阶目标教师不在实时等待链路中，只产出
Goal 教师标签；Action-S1 的困难样本和动作标签必须由独立 Action Teacher 在合法
候选边界上生成，详见 [教师体系](../../docs/system1-model/teacher.md)。

## 3. 统一输入契约

### 3.1 核心世界事件

窗口标题、前台应用、窗口出现/移动/缩放/最大化/最小化/遮挡/关闭和鼠标直接
互动属于核心世界输入。它们不能因为 AX/OCR 权限关闭而消失。

### 3.2 内容观察

AX、OCR、聊天、浏览器、编码/终端适配器输出统一的 ContentObservation：

~~~text
source        ax / ocr / chat / browser / coding
owner         应用或窗口
kind          内容类别
summary       有界文本或语义摘要
confidence    可信度
capturedAt    采集时间
expiresAt     内容有效期
observationID 稳定的观察标识
~~~

内容观察可以过期，不进入角色的长期记忆。原始内容和诊断记录可以保存在本机
record/brain trace 中，但不能借由观察绕过内核直接执行动作。

## 4. 优先级与生命周期

外部来源不是固定优先级；策略把世界事件转换成 BehaviorRequest：

~~~text
foreground change
        ↓
     GameEvent
        ↓
      Policy
        ↓
optional BehaviorRequest
~~~

优先级带定义如下：

| 优先级 | 来源 | 规则 |
|---|---|---|
| P0 | 点击、拖拽、戳、摸头、直接互动 | 立即打断可中断场景 |
| P1 | 前台或目标窗口变化 | 依策略抢占，不能等待内容读取 |
| P2 | 新聊天、编码状态、页面主题等内容变化 | 默认升级当前反应，不硬清空场景 |
| P3 | 普通轮询、背景感知和回合重规划 | 只能在没有更高请求时执行 |

每个行为请求至少带语义意图、目标句柄、需要的动作/交互 claim、PlanEpoch 和
过期策略。窗口切换、用户抢占或计划替换都会产生新的 epoch；旧异步结果必须被
内核丢弃。

## 5. 三条通道

### 5.1 抢占通道

P0 直接互动必须立即让当前可中断行为让权。P1 前台变化在满足策略时也可以抢占：
先靠近目标窗口并执行可用动作，不等待 OCR、AX、LLM 或内容插件。

抢占后的场景只能由 GameKernel 决定取消、暂停或恢复。表现层不能直接清理槽位、
所有权或剧情事实。

### 5.2 快速反应通道

本地决策脑先使用窗口标题、应用和活动类别生成第一次 QuickReaction，再使用
内容观察补充或升级它：

~~~text
窗口标题/应用活动
        → 第一次 QuickReaction
AX/OCR/聊天/浏览器/编码
        → 当前反应的补充或改写
~~~

QuickReaction 只能表达靠近、探头、陪伴编码、评论聊天、观看页面或开始短剧情等
高层意图。它不能输出坐标、素材文件名、鼠标操作或系统调用。Needle 负责选择
合法场景和语义动作；本地脑失败时回退规则和内置台词。

### 5.3 内容通道

内容来源逐项启用，并受权限、应用白名单、去抖、TTL 和长度预算限制。来源关闭、
权限缺失、结果超预算或 observation 过期时，只减少内容理解，不影响基础窗口
玩法和确定性抢占。

内容默认推动快速反应，不直接产生硬抢占。打开微信等窗口时的立即反应由前台
世界事件保证，即使 AX/OCR 全部关闭也必须成立。

## 6. 设置契约

“玩法/内容通道”设置由目录投影生成，至少支持：

- 总开关和每个来源的开关；
- TTL、最大字符数、去抖和应用白名单；
- 是否允许内容更新升级当前快速反应；
- 权限状态、最近错误和不可用原因；
- 是否记录原始内容到本机训练/回放 trace。

设置只保存稳定来源 ID 和用户覆盖值，不把显示名或插件顺序复制进 Swift。

## 7. Headless 验证

Harness 不启动真实窗口、AX、OCR 或 ScreenCaptureKit。VirtualDesktop 和
SensorSimulator 只产生可控数据，覆盖：

- 窗口出现、移动、缩放、最大化、最小化、遮挡和关闭；
- 应用切换、输入、说话、空闲、点击、戳、拖拽、释放；
- 六类插件的可用/不可用、延迟、超预算、TTL 到期和权限模拟；
- P0/P1 抢占、PlanEpoch、内容快照和旧结果丢弃。

这能证明逻辑降级和路由不变量，不能证明真实 macOS 权限、具体应用当前版本的
AX/OCR 结果或最终 AppKit 观感。真实平台验收必须单独报告。

## 8. 当前实现映射

当前代码中的 PerceptionHub 负责统一前台 revision、世界输入和多角色 perception
owner；InputPluginCatalog 提供窗口标题、AX、OCR、聊天、编码和浏览器适配器。
GameKernel 在 tick 中消费插件结果，WorldStateBuilder 将有效内容观察合并进
GoalBrain 的有界快照。

MyPetHarness 的 input-matrix 和语义链验证是逻辑证据，不是平台或素材完成证据。
动作素材的 exact/fallback/missing、普通角色 24+6、入场和出场覆盖由
[action-foundation.md](action-foundation.md) 与 [asset-audit.md](asset-audit.md)
分别记录。
