# DSH数字分身插件

DSH 数字分身的一键安装与分身指引 Tab。

## 快速安装

### 方式一：一行命令安装（GitHub raw，需仓库为 Public）

```powershell
irm https://raw.githubusercontent.com/lomehong/dsh-persona/main/install.ps1 | iex
```

自动下载仓库 zip（codeload，无需 git）→ 解压到 `~\dsh-persona\dsh-persona` → 分身配置向导
→ 桌面快捷方式 → 询问后直接启动；重复执行即为更新。
无人值守：先 `$env:DSP_SETUP_ARGS='-NonInteractive -Owner 甲子 -OwnerTitle 信息安全负责人'` 再执行。

### 方式二：私有仓库 / 内网托管（无需 clone、无需 git）

在任意 HTTP 服务器上托管仓库根目录的 `install.ps1` 与仓库 zip 包
（`git archive --format=zip --prefix=dsh-persona-main/ -o dsh-persona.zip HEAD` 生成，更新时重新生成）：

```powershell
$env:DSP_ZIP_URL='http://<服务器>/dsh-persona.zip'; irm http://<服务器>/install.ps1 | iex
```

### 方式三：clone 后一键安装

无需预装 Node.js / DSH——脚本会自动下载**便携版 Node.js 24** 到 `%LOCALAPPDATA%\dsh-persona`，
所有构建与运行都基于该便携环境，与系统 Node（及 nvm）完全隔离，不需要管理员权限。

> DSH 0.1.0-rc.x 要求 Node.js >= 23.8（`node:zlib` 的 zstd API），因此便携版固定为 Node 24 LTS。

```powershell
git clone https://github.com/lomehong/dsh-persona.git
cd dsh-persona
.\一键安装数字分身.bat -BotId "你的BotID" -Secret "你的Secret"
```

`一键安装数字分身.bat` 是**安装程序式入口**：完整安装（便携运行时、插件构建、分身配置向导）
→ 自动创建桌面快捷方式 → 询问「是否立即启动」，回车即启动——一个文件完成安装和启动。
等价的手动方式是直接运行 `.\scripts\setup.ps1`（参数相同，末尾同样会询问启动）。

也可不带参数安装（企业微信等稍后在设置页面配置）：

```powershell
.\一键安装数字分身.bat
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

安装完成后，双击仓库根目录（或插件目录）的 **`数字分身.exe`** 启动——原生桌面应用窗口，
**关闭窗口 = 最小化到系统托盘**（企业微信/御驿不中断），托盘右键菜单提供 显示/重启服务/
开机自启/彻底退出；日常日志写入 `%LOCALAPPDATA%\dsh-persona\dsh-web.log`。备用方式：
双击 `启动数字分身.bat`（控制台 + 浏览器）。

> 桌面应用基于 Tauri 2 构建（源码在 `app/`，Windows 用 WebView2、macOS 用 WKWebView，
> 单一代码库跨平台）。应用首次运行需已通过 setup.ps1 完成安装。

## macOS 安装（第二期）

```bash
git clone https://github.com/lomehong/dsh-persona.git
cd dsh-persona
./scripts/setup.sh -非交互参数示例见下
# 等价于 Windows 的向导：每项留空回车用默认值
./scripts/setup.sh            # 交互式逐项配置
```

非交互示例：`./scripts/setup.sh --non-interactive --bot-id "..." --secret "..." --owner "张三" --owner-title "首席技术官"`

- 运行时位于 `~/Library/Application Support/dsh-persona/node`（便携版，与系统 Node 隔离）
- 插件的 `@deepseek-ai` peer 依赖用 **symlink** 指向 DSH 自带依赖（对应 Windows 的 junction）
- macOS 桌面应用两条获取路径：
  1. **真机构建（推荐）**：Mac 上装有 Rust（`brew install rust`）与 Xcode Command Line
     Tools（`xcode-select --install`）时，`setup.sh` 会自动从 `app/` 源码构建
     `数字分身.app` 并安装到 `~/Applications`
  2. **CI 构建**：GitHub Actions（`build-macos.yml`）在 macos runner 上产出 `.app`/`.dmg`
     Artifacts（若 Actions 因账号额度/风控无法启动，需在 GitHub Settings → Billing 检查）
- 首次打开未签名应用：右键 `数字分身.app` → 打开，或在终端执行
  `xattr -cr ~/Applications/数字分身.app` 后再打开
- 企业微信 SDK 在 macOS 上的链路以 Actions 冒烟测试 + 真机实测为准

## 仓库

- [dsh-memory](https://github.com/lomehong/dsh-memory) — 共享记忆插件
- [dsh-im-bot](https://github.com/lomehong/dsh-im-bot) — 企业微信通道、MCP 工具注册
- [dsh-yuyi](https://github.com/lomehong/dsh-yuyi) — 御驿通信插件（Hub 接缝、会话 roster、yuyi_* 工具集、御驿 Web 标签页）

dsh-yuyi 的御驿工具会自动挂载进 digital-twin 预设，分身会话即可经 Hub 通信；其
`node_modules\@deepseek-ai` 由 setup.ps1 统一为指向 DSH 运行时依赖的 junction，
避免双实例导致的御驿 Tab「未配置」/接口 404 问题（见 dsh-launcher v1.3.1 的说明）。