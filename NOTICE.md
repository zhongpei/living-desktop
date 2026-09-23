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

以上文件均保留了指向原始项目的许可声明。其余部分为本仓库原创（MIT，
见仓库根 LICENSE）。

仅作行为/思想参考、未复制代码的项目：clawd（无许可证，零拷贝）、
ModDrag（无许可证，零拷贝）、MacArkPet（GPL-3.0，零拷贝）、
perchling（MIT，仅动画时间线思想）。


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
