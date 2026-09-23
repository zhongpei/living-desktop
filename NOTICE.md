# NOTICE — 第三方代码归属

本仓库代码在借鉴以下上游项目时，遵循了各自的许可证义务：

## Hopet — MIT License

- 来源：https://github.com/BinaryFroggy/Hopet
- 版权：© 2026 BinaryFroggy
- 使用范围：`Sources/MyPet/Render/OverlayPanel.swift`（非激活悬浮 NSPanel 的
  styleMask / collectionBehavior / constrainFrameRect 钳制模式，改自其
  `PetWindow.swift`）；`scripts/build-app.sh`（bundle 组装流程，改自其
  `scripts/build-release.sh`）。

## Rectangle — MIT License

- 来源：https://github.com/rxhanson/Rectangle
- 版权：© 2019-2026 Ryan Hanson
- 使用范围：`Sources/MyPet/AX/AXWindow.swift`（AXUIElement 属性读写的调用
  模式，提取自其 `AXExtension.swift` / `AccessibilityElement.swift` 并按需重写）。

以上文件均保留了指向原始项目的许可声明。本仓库整体以 GNU GPL v3
发布，见仓库根 LICENSE；上述 MIT 代码可在 GPL v3 下再分发。

仅作行为/思想参考、未复制代码的项目：clawd（无许可证，零拷贝）、
ModDrag（无许可证，零拷贝）、MacArkPet（GPL-3.0，零拷贝）、
perchling（MIT，仅动画时间线思想）。

## F.LF — GNU GPL v3

- 来源：https://github.com/Project-F/F.LF
- 本次核对版本：`21341737e4154d06d9784e9a629c9dd4db9148d6`
- 使用范围：`Sources/MyPetCombatCPU/ReferenceAlgorithms.swift` 中
  `keypress`、`keyseq`、缓冲与 `fetch` 的控制器边界。实现从 JavaScript
  控制器移植为强类型 Swift，并由固定行为测试约束。
- 许可证：GNU GPL v3，与本仓库根 LICENSE 相同。

## Surfacer — MIT License

- 来源：https://github.com/SnoringCatGames/surfacer
- 本次核对版本：`04058c560e8804a15697e6592fda3f4bfa5057cc`
- Copyright (c) 2021-2026 Snoring Cat LLC
- Copyright (c) 2019-2021 Levi Lindsey
- 使用范围：`Sources/MyPetCombatCPU/SurfaceGraph.swift` 的 surface/trajectory
  分层、确定性路径图与行走/跳跃/下落边语义；实现缩减并改写为 Swift。

## MctsAi23i — no license, compatibility only

- 来源：https://github.com/TeamFightingICE/MctsAi23i
- 本次核对版本：`b05afc13f6b0815ff154d19ca7e76c99c172799b`
- 使用范围：只复现公开可观察的 UCT 参数和通用 UCB1 数学公式；没有复制
  Java 源码。仓库许可证改为 GPL v3 不会替无许可证代码补授权。

## FightingICE — author-approved GPL v3 use

- 来源：https://github.com/TeamFightingICE/FightingICE
- 本次核对版本：`188fca0c13151b559ec3a4ca60b90a9b7efb6cc3`
- 授权依据：项目所有者已向 FightingICE 作者确认可在本 GPL-3.0 仓库中
  直接参考和移植。
- 使用范围：`Sources/MyPetCombatCPU/ReferenceAlgorithms.swift` 的
  CommandCenter 队列边界，以及 `ClassicCombatCPU` 使用真实 CombatWorld
  checkpoint 执行固定帧数 rollout 的 simulator 边界。

## OpenBOR — BSD-style License

- 来源：https://github.com/DCurrent/openbor
- 本次核对版本：`787b6770409935137579715febf80cf7a529b748`
- Copyright (c) 2003, Roel van Mastbergen & Senile Team
- Copyright (c) 2004, OpenBOR Team
- 使用范围：Classic Combat CPU 的 chase、avoid、aggression 和地形风险行为
  词汇参考；没有复制 OpenBOR C 源码。


## Fighters Paradise — MIT License

- 来源：https://github.com/fakoli/FightersParadise
- 本次核对版本：`4f67007bfa4448e2e254b69a386b61407360ec3c`
- Copyright (c) 2025 Sekou Doumbouya
- 使用范围：`Sources/MyPetCombat/` 的固定 60Hz、输入缓冲/指令识别、
  AABB Clsn 风格攻击/受击框、push body、命中数据边界与 headless/replay
  设计参考；Swift 实现按 Living Desktop 的桌面多 Surface/N 角色模型改写。

## IKEMEN GO — MIT License

- 来源：https://github.com/ikemen-engine/Ikemen-GO
- 本次核对分支：`develop`（2026-09-23）
- Copyright (c) 2016-2026 Ikemen GO contributors
- 使用范围：MUGEN 风格 state/hit/guard/hitpause/knockdown 语义的交叉校验。
  本仓库不打包 IKEMEN 的美术资源，也不宣称兼容完整 MUGEN 文件格式。

上述两项适用 MIT 条款：

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished
to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
