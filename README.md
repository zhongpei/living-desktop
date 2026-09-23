# Living Desktop

Living Desktop 是运行在 macOS 桌面上的 AI 角色游戏。角色把真实屏幕当成游戏场景，
会在窗口和桌面之间移动、回应用户、使用道具，并和其他角色共同演出短剧情。

## 可以怎么玩

- **直接互动**：拖动、抛出、点击角色，观察角色落地、移动和即时回应。
- **桌面活动**：角色会散步、休息、观察前台窗口，也能坐到窗口边缘或跟随窗口。
- **角色表演**：每个角色共享问候、思考、开心、睡觉等基础语义，同时可以拥有符合
  自己身份和性格的特色动作。
- **多角色剧情**：角色可按关系相遇、合作、争执、战斗、传递道具或进入机甲。
- **自主/人工格斗**：具备战斗内容的角色可自主交战，也可从角色菜单临时“接管控制”，使用方向键与 Z/X/C、A/S/D 操作；HP 归零后倒地并自动恢复。
- **环境玩法**：玩法可以使用桌面窗口、座位、手部插槽、道具和视觉特效，但不会修改
  外部应用的真实内容。
- **本地大脑**：角色可根据窗口标题和可选的屏幕内容作出短反应；关闭模型后仍可使用
  内置规则正常游玩。

完整玩法与扩展方式见 [玩法说明](docs/gameplay.md)，统一身体、格斗、模拟器与可替换渲染边界见 [combat-runtime.md](docs/combat-runtime.md)。

## 下载与运行

请从 [GitHub Releases](https://github.com/zhongpei/living-desktop/releases)
分别下载“程序”与“角色内容”：程序包包含应用、基础规则和本地行动脑模型，
不预装角色；从角色内容 Release 下载所需的 `.mypetpack`，在应用的“内容包”
管理页导入。角色组包可独立运行基础玩法；剧情包需对应角色组包。程序版本会继续
更新，已有角色包保持稳定，后续新增角色或剧情以新包追加。

本仓库只保存代码和公开配置契约，不保存美术资源，因此直接从源码运行时需要自行提供
兼容的资源包：

```bash
MYPET_PETPACK=/path/to/petpack swift run
swift test
```

需要隔离桌面 smoke 的设置时，可额外设置绝对路径 `MYPET_SETTINGS_PATH=/path/to/settings.json`；
应用将只在该文件读写设置，不触碰日常 `MyPet/settings.json`。

要求 macOS 14 或更高版本。辅助功能、屏幕内容读取等能力是可选功能；基础角色互动不应
依赖这些权限。

## 项目结构

```text
Sources/MyPetEntry/  可执行程序的薄入口
Sources/MyPet/       MyPetApp：AppKit 装配、菜单和角色控制
Sources/MyPetCore/   世界事实、纯数据定义和确定性规则
Sources/MyPetCombat/ 60Hz 身体/格斗：输入、物理、碰撞、命中、HP、倒地恢复
Sources/MyPetEngine/ 唯一运行时、语义链和剧情协调
Sources/MyPetSimulation/ 虚拟桌面、场景和确定性回放（测试/Harness 使用）
Sources/MyPetContent/ 内容包校验、安装登记与目录解析
Sources/MyPetRender/ 可替换渲染边界；默认 AppKit + Core Animation/CALayer
Resources/           公开玩法与资源契约，不含美术文件
Tests/               离线测试
docs/gameplay.md     公开玩法说明
docs/combat-runtime.md 统一身体/格斗/模拟器/渲染架构
```

## 许可证

代码采用 MIT License。第三方归属见 [NOTICE.md](NOTICE.md)。
