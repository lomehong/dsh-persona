# DSH数字分身插件

DSH 数字分身的一键安装与分身指引 Tab。

## 快速安装

无需预装 Node.js / DSH——脚本会自动下载**便携版 Node.js 24** 到 `%LOCALAPPDATA%\dsh-persona`，
所有构建与运行都基于该便携环境，与系统 Node（及 nvm）完全隔离，不需要管理员权限。

> DSH 0.1.0-rc.x 要求 Node.js >= 23.8（`node:zlib` 的 zstd API），因此便携版固定为 Node 24 LTS。

```powershell
git clone https://github.com/lomehong/dsh-persona.git
cd dsh-persona
.\scripts\setup.ps1 -BotId "你的BotID" -Secret "你的Secret"
```

安装过程会以**向导形式逐步配置分身信息**，每一项留空回车即使用默认值：

| 项目 | 参数 | 默认值 |
|---|---|---|
| 主人姓名 | `-Owner` | 主人 |
| 职务/角色 | `-OwnerTitle` | 公司副总裁 |
| 人设定位（AI 与主人的关系） | `-OwnerStance` | 专属 AI 协作伙伴 |
| 分管领域/工作范围 | `-OwnerScope` | 人力资源、审计、信息安全、总裁办等管理领域 |
| 工作习惯/沟通风格 | `-OwnerStyle` | 直接、务实、结构化；先结论再展开；善用分点、表格 |
| 称呼习惯（分身对主人的称呼） | `-OwnerAddress` | 主人 |
| 分身名字（分身的自称） | `-TwinName` | {主人姓名}的数字分身 |
| 分身别名（哪些称呼指它自己，逗号分隔） | `-TwinAliases` | 分身 |

配置摘要确认后，人设会同步写入 agent 预设与 system-prompt patch。其中「分身名字/别名」让分身有清晰的自我认知：知道别人叫哪些名字是在叫它、以什么自称，并明确自己**不是主人本人**而是主人的数字分身。也可以全部用参数传入（适合非交互/自动化），例如：

```powershell
.\scripts\setup.ps1 -BotId "你的BotID" -Secret "你的Secret" -Owner "张三" -OwnerTitle "首席技术官" -OwnerAddress "张总"
```

安装完成后，双击仓库根目录（或插件目录）的 **`启动数字分身.bat`** 启动，浏览器会自动打开
http://127.0.0.1:3080。关闭该窗口即停止数字分身。

## 仓库

- [dsh-memory](https://github.com/lomehong/dsh-memory) — 共享记忆插件
- [dsh-im-bot](https://github.com/lomehong/dsh-im-bot) — 企业微信通道、MCP 工具注册
- [dsh-yuyi](https://github.com/lomehong/dsh-yuyi) — 御驿通信插件（Hub 接缝、会话 roster、yuyi_* 工具集、御驿 Web 标签页）

dsh-yuyi 的御驿工具会自动挂载进 digital-twin 预设，分身会话即可经 Hub 通信；其
`node_modules\@deepseek-ai` 由 setup.ps1 统一为指向 DSH 运行时依赖的 junction，
避免双实例导致的御驿 Tab「未配置」/接口 404 问题（见 dsh-launcher v1.3.1 的说明）。