# Brain v1（历史）：WorldState + BrainState + Qwen Teacher

> 状态：历史设计，Goal/Action 运行时已由 Game v2 取代。当前三档大脑、教师标签和设置契约以
> [game-v2.md](game-v2.md) 与仓库根 [brain-local.md](../../brain-local.md) 为准。前序：[ax-perception.md](ax-perception.md)。

## 转折点

「怎么让宠物看到桌面」已解决（AX 覆盖结构化应用，微信证伪）。本阶段核心问题换成：

> **看到了以后，它为什么会产生一个行为？**

三条主线：Perception（AX ✓ / OCR 实验中 / VLM 待证伪）→ **Brain（本阶段重点）** →
Action（收缩为 observe/move/perform/speak/wait）。

## 新增概念与实现

### WorldState v1（`Brain/WorldState.swift`）—— 唯一稳定边界

AX/OCR/系统事件的原始输出**不再直接进大脑**，一律先压成快照：

```text
active_app / window / user_activity(editing_text|browsing|idle) / focus_role
visible_context(≤6 行×60 字符) / salient_ui(≤8) / nearby_windows(≤5) / recent_events(≤5)
```

- 装配是纯函数（`WorldStateBuilder`），离线可测；
- 传感器换实现（AX 换 OCR、VL 换模型）不影响 Brain 上下两侧；
- 整包 ~600 字符级，teacher 与未来 student 快照都背得动。

### BrainState v1（`Brain/BrainState.swift`）—— 内部状态

4 个 0~1 变量 + 注意/目标/最近言行，只有简单动力学，没有神经科学：

- `energy`：动多了降（移动 ×2），睡/闲恢复；
- `curiosity`：世界变化 ×3 加速上涨，探索后回落；
- `socialNeed`：随时间上涨，说话 -0.35、表演 -0.15；
- `Personality.forCharacter(id)`：同一世界不同动力学——**默认角色活泼外向；
  lin_daiyu 好奇收敛、社交矜持、易倦**（curiosityGain 0.012 vs 0.020）。
  「狗跑过去看、黛玉默默观察」从这一行开始成为可能。

决策反馈闭环：`apply(decision:)` 让「做了事会累、说了话会被满足」，teacher 因此
能读到行为后果，行为才有连贯性（currentGoal/lastAction/lastSpeech 都在快照里）。

### BrainDecision（`Brain/BrainDecision.swift`）—— 大脑输出契约

```json
{"mode":"observe|react|explore|rest",
 "target":"user|focused_window|window_<id>",
 "action":"wait|observe|move_to|perform|speak|sleep",
 "perform":"<动作名>", "speech":"<≤60字>", "why":"<理由，只进日志>"}
```

语义校验与 NeedleBrain.validate 同哲学：参数必须被当前 WorldState 完全支撑
（move_to 的窗口必须在场、perform 必须在表演池、speak 必须有内容），拒绝即丢弃。

### TeacherBrain（历史契约）—— 当前对应高阶教师脑

- 历史契约是 `WorldState + BrainState → BrainDecision`；当前契约是高阶教师脑产生 `GoalDecision`；
- 当前实现由本机 `llama.cpp` 启动 Qwen VLM，使用 OpenAI 兼容端点，并支持模型侧 multimodal 能力；
- 配置（环境变量）：`MYPET_TEACHER_BASE_URL` / `MYPET_TEACHER_MODEL` / `MYPET_TEACHER_KEY`；
- 缺配置只关闭高阶教师脑，不影响本地决策脑或行动脑；
- 高阶教师脑与本地决策脑可同时运行；它输出的是本地决策脑的 Goal 教师标签，
  不是 Action-S1 的下一步动作标签；
- 当前统一日志为 `brain_trace.jsonl`；高阶教师脑只暴露 Goal 决策采样参数，不暴露独立语音采样参数。

### Action 收缩 + 气泡

- verbs 保持六种：observe（原地看）/ move_to / perform / speak / wait / sleep；
  不做点击/输入/拖窗——评价指标是「桌面上有个活着的角色」，不是自动化能力；
- `Render/SpeechBubble.swift`：非激活置顶小面板 + 圆角底，显示 5s 自动淡出，
  即「能表达」的最小实现。

## 与 Needle 的关系（重定位，未动代码）

Needle 仍是行动脑，不承担高层 Goal 学生训练：等真实桌面跑出几千条 `(WorldState, BrainState) → TeacherDecision`
样本再谈本地决策脑蒸馏（`needle finetune` 路线不变，见 needle-brain.md）。若实验发现 Needle
对情绪/关系/长期目标表达不动，就让它定格在 action router——快速放弃不恋战。

## 待办实验（按优先级）

| # | 实验 | 判据 | 状态 |
|---|---|---|---|
| 1 | **Vision OCR 对微信**（`experiments/ocrprobe/`） | 聊天文字能否稳定读出；截图+OCR 单帧成本 | **✅ 2026-09-20 实测通过，见下** |
| 2 | 高阶教师脑真实运行几天 | 行为像不像「自主生命」（主观 + brain_trace.jsonl 分布） | 本机 llama.cpp Qwen VLM 端点已可探测，待真实运行 |
| 3 | A/B/C/D 四组对照（WindowWorld / +AX / +OCR / +截图） | C≈D → 放弃本地 VLM；D≫C → 才立项 Qwen3-VL-2B MLX | A/B/C 语料已有，D 待截图 |
| 4 | Needle 蒸馏与去留 | 蒸馏后行为分布 vs teacher 分布 | 攒样本后 |

## OCR 实测结论（2026-09-20，微信 4.x 真实聊天窗）

判据（预注册）：accurate 单帧总成本 ≤300ms 且关键消息行可读 → 立项。

| 配方 | 截图 | OCR | 总成本 p50 | 中文可读性 |
|---|---|---|---|---|
| 全窗 accurate（1870×1362） | 10ms | 271~306ms（抖到 475） | ~316ms 贴线 | ✅ 消息行清晰（置信 0.3~1.0，UI 杂讯可用置信过滤） |
| 全窗 **fast** | 10ms | 22ms | 32ms | ❌ **中文全乱码**（`/Jlb`、`%IJAif*`），fast 档对微信不可用 |
| **裁右侧 44% 聊天区 + accurate**（生产配方） | 10ms | **114ms** | **~124ms** | ✅ |

**结论：立项为第二传感器**——生产配方（截图→裁聊天区→accurate）~124ms，
远低于 300ms 预算；关键消息行可读。要点：

1. fast 档便宜 10 倍但读不了中文，微信 profile 固定 accurate。
2. 单帧抖动大（±40%），按 10~18s 决策节奏跑（占空比 ~1%）无压力；不追求 p95。
3. 裁剪比例对耗时**非单调**（55% 裁剪反而 379ms > 全窗 271ms），生产按
   bundleID profile 配 crop，用同一探针标定。
4. WorldState.visibleContext 上限 6 行×60 字符=360 字符，聊天区 95 字符足够喂大脑。
5. 授权经验：屏幕录制和辅助功能一样要「新鲜生效」——勾选 ZCode 后已运行的
   ZCode 及旧子进程仍被拒，**重新勾选开关即对新进程生效，无需重启宿主**；
   探针要自己调 `CGRequestScreenCaptureAccess()` 才会出现在授权列表里。

冒烟证据：`/tmp/ocr_bench.json`（10 帧 p50/p95）、`/tmp/ocr_zcode.json`（42 行
330 字符全窗读取）、`/tmp/mock_teacher_hits.log`（teacher 链路 mock 冒烟）。

## OCR 实验操作

```bash
cd desktop/experiments/ocrprobe
./build_ocr_app.sh          # 已构建过则跳过
open -n OCRProbe.app --args request        # 首次：弹屏幕录制授权框
# 系统设置 → 屏幕录制 → 勾选 OCRProbe（勾完无需重启，open -n 即生效）
open -n OCRProbe.app --args capture --app 微信 --json /tmp/ocr_wechat.json
open -n OCRProbe.app --args bench --app 微信 --count 10 --interval 1 --json /tmp/ocr_bench.json
```
