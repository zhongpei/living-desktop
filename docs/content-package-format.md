# `.mypetpack` 内容包格式（v1）

`.mypetpack` 是单个 ZIP，根目录必须有 `package.json`。它只能携带配置、图像和动作音频，不执行脚本或动态代码。SHA-256 校验包内文件完整性，**不证明作者身份**。

~~~json
{
  "formatVersion": 1,
  "kind": "story",
  "id": "journey_west_main",
  "revision": 1,
  "name": "西游记剧情",
  "content": "content/story.json",
  "targetGroupID": "journey_west",
  "files": [
    {"path": "content/story.json", "sha256": "64 个小写十六进制字符"}
  ]
}
~~~

`kind` 为 `role`、`group`、`story`。ID 是稳定的 ASCII 小写标识，修订号为正整数；同种类同 ID 的更高修订版才可作为显式更新候选。剧情包必须声明目标 `targetGroupID`，角色和组包不能声明它。

| 类型 | 主内容 | 其他文件 |
|---|---|---|
| 角色 | `content/role.json`：`CharacterDefinition`，ID 等于包 ID | `petpack/<角色ID>/` 的 manifest、帧和可选动作音频 |
| 角色组 | `content/group.json`：`GroupPackagePayload`（组定义、CastPack、成员档案），CastPack 不含剧情 | 组内角色的 `petpack/<视觉ID>/` 和所需道具素材 |
| 剧情 | `content/story.json`：`StoryPack`，ID/目标组与包清单相符 | 无；只引用目标组已有成员、道具、槽位和能力 |

动作语音与对应动作 clip 放在一起：`petpack/<视觉ID>/actions/<动作ID>/voice.mp3`。它是可选素材；普通动作默认不生成，角色专属特色动作由素材工厂的动作级字段显式申请。MP3 同样列入 `files` 并计算 SHA-256。剧情包不能携带音频；每个 MP3 解压后不超过 32 MiB。

读取器先检查整个 ZIP 的条目数量、路径、类型、解压总量、单个 JSON/MP3 大小、清单白名单及哈希，再允许提取到新目录。上限：20,000 条、1 GiB 解压总量、单个 JSON 16 MiB。拒绝绝对或遍历路径、空/隐藏组件、重复的大小写归一化路径、符号链接、未知 Unix 条目类型、ZIP64/多磁盘、清单外文件、文件/目录冲突和缺失帧。ZIPFoundation 固定 0.9.20；不使用无条件整包解压。

私有发布流程已可确定性导出角色、组与独立剧情包。`MyPetContent` 将 ZIP 校验、安装登记、启停及目录解析分开；生产应用仅消费已启用且解析通过的目录快照。活动包操作先退休当前会话，再移除归档或切换版本。多个剧情包可以绑定同组，运行时剧集 ID 以包 ID 限定。AppKit 动作音频由独立的持久总开关控制；包内没有音轨时保持静音。真实平台交互和音画效果仍需单独验收，不能由包格式测试推定。
