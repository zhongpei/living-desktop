# 屏幕感知（Accessibility）实验报告与最终架构

> 状态：E0/E0.5 实验完成，E2 运行时集成已落地（默认关），E1 harness 就绪待评分。
> 日期：2026-09-20。方法论：实验门控——先做可丢弃实验，只有被数据支持的架构才保留。

## 一句话结论

**辅助功能权限（新鲜生效）下，AX 可以读到 Chrome/Electron 应用的完整窗口内容
（含网页 DOM 语义树），微信只能读到窗口骨架；focused-context 范围读取 ≤30ms，
进程内实现安全；感知已接入 Needle 快照（`sensesEnabled`，默认关），并随本机
`brain_trace.jsonl` 保存决策时的快照。**

## 五个问题（实验前预注册）的答案

| # | 问题 | 答案 | 证据 |
|---|---|---|---|
| 1 | Chrome 实际能读多少？ | **激活后完整网页语义树**。窗口级 324 节点：group 122 / statictext 50 / link 45 / button 19 / heading 19 / editable 1，26ms 走完。未激活时只有自引用骨架 + 菜单（app→app 无限嵌套） | `results/e0/chrome_window_v2.json` |
| 2 | 微信实际能读多少？ | **窗口骨架而已**：窗口级 5 节点（window + 3 无名 button + group）。聊天/联系人/输入框零暴露，自绘控件实锤。对微信走 OCR/VLM 是唯一路径 | `results/e0/wechat_window_v2.json` |
| 3 | AX 树获取多慢？ | 每节点 ~43µs（Chrome，`CopyMultipleAttributeValues`），focused-context（≤300 节点预算）≤30ms。慢应用画像：微信 p50≈5.8ms/调用、Safari≈2.3ms、Chrome≈43µs——预算上限是必要的 | `results/benchmark_locked_check.json`、dump elapsed |
| 4 | notification 可靠性？ | **未证实**。30s 静置窗口期零通知（实验期间无目标应用交互）。现行 dirty→resense + TTL 轮询兜底设计因此成为正确默认；AXObserver 留作后续独立实验（runbook §runbook） | `results/e0/watch_chrome.json` |
| 5 | helper 的权限表现？ | 见下方矩阵。核心事实：**辅助功能授权必须「新鲜生效」**（列表里有 + trusted=true 仍可能 blocked；重新勾选/重开即恢复）；**屏幕录制权限不需要** | `results/tcc_matrix.jsonl` |

## E0.5 权限矩阵（实测记录）

| 时刻 | 身份 | trusted | screen | menubar | 窗口可达 |
|---|---|---|---|---|---|
| 05:53 | 终端宿主（ZCode） | ✅ | ❌ | ✅ | ❌ blocked |
| 05:54 | TCCProbe.app（零授权） | ❌ | ❌ | ❌ | ❌ blocked |
| 06:1x | 终端宿主（授权刷新后） | ✅ | ❌ | ✅ | ✅ **reachable** |

### 假设修正记录（诚实归档）

1. **「屏幕录制是 AX 窗口内容的门控」——被推翻。** 授权刷新后窗口即达，
   而 `CGPreflightScreenCaptureAccess` 仍为 false。
2. **「AXIsProcessTrusted=true 即可读」——不完全对。** 存在 trusted=true 但窗口
   blocked 的中间态；重新走一遍授权流程（重勾选）后解除。诊断规律：
   菜单可达 + 窗口 blocked = 授权陈旧态，重新勾选辅助功能开关。
3. **「Chrome 一次 --dump 就能判定」——正如最终决策预警的，不行。** Chromium
   progressive accessibility：未激活时 app 元素自引用嵌套、无窗口；激活信号包括
   AX 客户端持续访问 + 用户交互。`AXEnhancedUserInterface` / `AXManualAccessibility`
   在 Chrome 153 上设置均被拒（-25208 / -25205），不能远程强制。
4. Safari / Electron（ChatGPT 桌面版）授权后同样完整可达；Electron 的聚焦元素
   实测能拿到输入框实时内容（见 E1 语料 C 变体）。

### 复现实验（runbook）

```bash
cd desktop/experiments
./run_e0.sh                       # 全套重跑，输出 results/e0/<时间戳>/
# 可选补充：
open -n tcc/TCCProbe.app --args tcc --prompt-ax   # TCCProbe 进辅助功能列表（勾选后重跑 tcc 行）
# 通知实验：跑 run_e0.sh 第 5/6 步时， actively 操作 Chrome / 往微信发消息
axprobe scene --level c --digest full --out results/e1-corpus   # 全树 digest 语料
```

## 延迟基准：single vs CopyMultipleAttributeValues

同一 2000 节点树（Chrome 菜单域），3 轮取末轮：

| 方式 | 全树耗时 | p50/调用 | p95/调用 | max | 超时 |
|---|---|---|---|---|---|
| single（每属性一次 IPC） | 306ms | 17µs | 47µs | 3.5ms | 0 |
| **multiple（批量）** | **140ms** | 44µs/批 | 125µs | 1.2ms | 0 |

批量接口端到端 **2.2×**（每节点 70µs vs 153µs），生产 AXSensor 采用批量。
首访激活成本：Chrome 首次 dump 1460ms → 热访问 158ms → 授权+激活后 26ms。

## E3 门控决策：进程边界

**in-process（现行），子进程契约保留不实现。** 依据：
- focused-context 范围 ≤300 节点预算 → 最坏 ≤30ms（Chrome），慢应用由 0.1s
  messaging timeout 封顶，串行 utility 队列隔离，40fps 主循环零阻塞风险；
- 「AX 会卡死 → 必须子进程」未获数据支持（300+ 次实测调用零超时、零卡顿）；
- TCC 实测表明权限绑定宿主身份，.app 内子进程并不改变权限面（矩阵行对比）；
- 感知量级小（决策间隔 4~10s 一次），无常驻成本。
若将来出现真实卡死案例，`SensorContract` 数据形状可直接迁移到子进程 transport。

## E2 落地（已合入 Sources/MyPet/Senses/，默认关）

| 文件 | 职责 |
|---|---|
| `SensorContract.swift` | 数据形状：`SensorObservation` / `AXElementDTO` / `SensorEvent`；`sensesJSON()` 有界化（≤1200 字符，四级降档：砍 salient→nearby→ancestors）；opaque id `ax:<pid>:<path>` 宿主不解释（为将来 provider 兼 act 预留） |
| `AXSensor.swift` | 聚焦上下文读取：focused element + 祖先链(≤6) + 同父兄弟±3 + 选中文字 + salient(≤12, ≤300 节点预算)；批量属性 IPC；0.1s messaging timeout；专用串行队列 |
| `SensesStore.swift` | TTL(6s) + 脏标记防抖(2s)；**事件=感知失效通知，不是行为事件**——脏了→重感→WorldState 变化→大脑决定反应 |
| `NeedleBrain` 扩展 | `modelInput() = snapshot + senses 段`；统一 `brain_trace.jsonl` 保存决策时的 senses，保证查看器能关联完整输入；toolSchema/validate 零改动（senses 是描述性字段） |
| `PetController` | 0.3s 轮询时按 TTL/脏标记重感；前台变化 markDirty；`settings.sensesEnabled` 总闸（默认关） |

测试：`Tests/MyPetTests/SensesTests.swift` 9 项（契约 roundtrip / 预算降档 / TTL /
防抖 / id 透明性），桌面全包 **69/69 绿**。

## E1：脑价值实验（harness 就绪，待评分）

- 采集：`axprobe scene --level a|b|c`，语料在 `experiments/results/e1-corpus/`
  （a/b/c 三档已采，场景=「用户在 ChatGPT 输入框粘贴 GitHub 链接」）；
- 评分：`experiments/e1/judge.py`（OpenAI 兼容端点，env 提供 teacher）；
- 判据预注册：B≈C → 生产只做聚焦元素；C 无提升 → 感知线降级；否则按现行
  focused-context 范围（即已实现形态）。

## 后续路线（按最终决策的数据驱动顺序）

1. **E1 评分** → 定 senses 段最终形态（focus-only vs context）；
2. **AXObserver 独立实验**（runbook）→ 若通知可靠，TTL 轮询升级为事件驱动；
3. **Vision OCR sensor**（微信等自绘应用的唯一路径）→ 出现第二个 sensor 后
   才抽 SensorProvider/manifest（第三次重复才抽象）；
4. **按 bundle id 的 sensor profile**（如 Chrome→AX，微信→OCR）而非全局仲裁器；
5. **CaptureBroker**（宿主独占屏幕采集，frame_ref 传递）在 OCR 立项时一并设计；
6. Chrome 深度集成走 Extension 路线，CDP 已从通用链删除（Chrome 136+ 默认
   数据目录禁远程调试，不适合无感方案）。
