# Living Desktop — AI 桌面角色游戏

Living Desktop 把 macOS 桌面变成一个 AI 角色共同生活的 2D 游戏世界：角色可以在
地板和真实窗口表面移动、停留、跟随窗口、被用户拖拽，并参加多角色、道具和屏幕剧情。

玩法总规格见 [gameplay-requirements.md](docs/gameplay-requirements.md)；运行时实现地图见
[game-v2.md](docs/game-v2.md)；动作和素材契约见
[action-foundation.md](docs/action-foundation.md)。

## 快速开始

~~~bash
swift run
swift test
~~~

本代码仓库不保存角色帧、道具图或特效图。可直接运行的完整 `.app` 从 GitHub Releases
下载；维护者构建发布包时，通过 `LIVING_DESKTOP_RESOURCES` 指向私有素材目录后执行
`scripts/build-app.sh`。运行时仍支持 `MYPET_PETPACK` 指向外部角色包。

## 玩法入口

| 语义 | 默认中文显示 | English |
|---|---|---|
| 常见基础动作 | 问候、开心、思考、抱怨、调侃、睡觉等 | Greet, Happy, Think, Complain, Tease, Sleep |
| 窗口停留 | 坐在窗口上 | Perch on Window |
| 角色入场/出场 | 入场 / 出场 | Enter Scene / Exit Scene |
| 战斗能力 | 嘲讽、攻击、防御、闪避、受击 | Taunt, Attack, Defend, Dodge, Hit React |
| 窗口破坏 | 裂痕、弹孔、冲击、碎片、烟雾 | Crack, Bullet Hole, Impact, Shards, Smoke |

普通角色的统一最低目标是 24 个基础动作、6 个公共扩展和两个生命周期动作；
完整清单与中英文对照不在 README 复制，以 action-foundation 为唯一来源。

窗口停留不是所有角色都直接播放“坐下”：角色可以 direct_perch（直接登上）、
climb_perch（攀爬登上）、swing_perch（荡到窗台）或 lean_window（倚靠窗口）。
窗口关闭、最小化或 slot 失效时，由 GameKernel 处理脱离和出场/掉落。

正式 taunt/战斗需要角色声明 combat 能力。窗口破坏由 WindowDamageEvent 驱动
EffectCatalog，只覆盖 Living Desktop 表现层，不修改真实外部窗口。

所有动作、角色、道具、玩法和特效配置提供稳定英文 ID、中文标签和英文标签；
默认菜单显示中文，详情和诊断显示中文/English 对照。

## 平台边界

- CoreGraphics 读取窗口 ID、owner、bounds、layer 和 alpha；
- 基础窗口识别、窗口跟随和用户直接互动不依赖 Accessibility；
- Accessibility 只扩展窗口操作或可选内容读取；
- AppKit 只消费 GameKernel 已提交的角色、道具、特效和空间投影；
- 真实平台权限、应用会话和最终视觉观感必须由真实应用验收。

## 目录结构

~~~text
.
├── Sources/MyPet/          App / World / Game / Pet / Render / AX
├── Sources/MyPetCore/      GameKernel / WorldState / 剧情与确定性规则
├── Resources/              公开配置契约，不含角色和道具美术
├── Resources/gameplay/     玩法目录与插件配置
├── Tests/                  离线单测与运行时回归
└── scripts/                发布构建与模型获取工具
~~~

## 验收

验收分为：

1. Logic：事件、tick、抢占、slot、关系、剧情、入退场和特效事件；
2. Content：24+6、enter/exit、window profile、combat、角色/道具/特效中英文
   标签与 exact/fallback/missing；
3. Platform：真实 AppKit、多窗口、权限、WebP、布局和最终观感。

## 许可证

本目录代码 MIT（随仓库 LICENSE）。第三方代码归属见 NOTICE.md；外部项目只作
行为和架构参考，不作为当前玩法契约。
