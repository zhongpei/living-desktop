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
