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

### Linux / macOS 一行安装

```bash
curl -fsSL https://raw.githubusercontent.com/lomehong/dsh-persona/main/install-macos.sh | bash
```

- 无需 git、无需 clone：codeload 下载仓库与全部插件（tar.gz）
- Linux 运行时位于 `~/.local/share/dsh-persona`（macOS 为 `~/Library/Application Support/dsh-persona`）
- 生成启动器 `~/dsh-persona/start-persona.sh`（Linux；已运行检测/自动开浏览器/前台 Ctrl+C 停止）
- 无人值守：`export DSP_SETUP_ARGS='--non-interactive --owner 甲子 --owner-title 信息安全负责人'` 后执行
- 内网托管：`export DSP_TARBALL_URL='http://<服务器>/dsh-persona.tar.gz'`（包用
  `git archive --format=tar.gz --prefix=dsh-persona-main/ -o dsh-persona.tar.gz HEAD` 生成）

### 方式三：clone 后一键安装

无需预装 Node.js / DSH——脚本会自动下载**便携版 Node.js 24** 到 `%LOCALAPPDATA%\dsh-persona`，
所有构建与运行都基于该便携环境，与系统 Node（及 nvm）完全隔离，不需要管理员权限。

> DSH 0.1.x 要求 Node.js >= 23.8（`node:zlib` 的 zstd API），因此便携版固定为 Node 24 LTS；DSH 固定安装 `@deepseek-ai/dsh@0.1.1-rc.2`（`-DshVersion` 参数 / `DSH_VERSION` 环境变量可覆盖）。

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

安装完成后，双击桌面的 **`数字分身`** 快捷方式启动 **DSH Desktop** 桌面宿主（setup 自动从
[lomehong/dsh-desktop](https://github.com/lomehong/dsh-desktop) Release 下载安装， ghfast 代理兜底）——
无边框原生窗口 + OS 原生通知（回合完成/审批请求），**关闭窗口 = 最小化到系统托盘**
（企业微信/御驿不中断），托盘右键菜单提供 显示/重启服务/升级 DSH/检查应用更新/开机自启/彻底退出。
与本脚本共享 `~/.dsh`：im-channel 绑定、共享记忆、分身 preset 全部沿用。旧版 `数字分身.exe` 会被
自动移除；备用方式：双击 `启动数字分身.bat`（控制台 + 浏览器）。桌面应用数据目录
`%LOCALAPPDATA%\dsh-desktop-app-data`（v0.1.1+，与安装目录隔离）。

> 桌面宿主源码在独立仓库 [dsh-persona/../dsh-desktop](https://github.com/lomehong/dsh-desktop)；
> 本仓库 `app/` 下的旧 Tauri 壳已退役，仅保留参考。

## macOS 安装

### 方式一：一行命令安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/lomehong/dsh-persona/main/install-macos.sh | bash
```

等价于 Windows 的方式一，自动下载仓库、配置分身信息向导、安装桌面应用。
无人值守：先设置环境变量再执行：

```bash
DSP_SETUP_ARGS='--non-interactive --owner "张三" --owner-title "首席技术官"' \
  curl -fsSL https://raw.githubusercontent.com/lomehong/dsh-persona/main/install-macos.sh | bash
```

私有仓库 / 内网：在 HTTP 服务器上托管 `install.sh` 和仓库 zip 包，设置 `DSP_ZIP_URL`：

```bash
curl -fsSL http://<服务器>/install.sh | DSP_ZIP_URL=http://<服务器>/dsh-persona.zip bash
```

### 方式二：clone 后本地安装

```bash
git clone https://github.com/lomehong/dsh-persona.git
cd dsh-persona
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
- [dsh-model-failover](https://github.com/lomehong/dsh-model-failover) — 模型自动降级插件（套餐超限/余额不足时按成本优先级链自动切换模型，窗口重置后自动切回；在 设置 → 模型切换 配置降级链，未配置时不生效）

dsh-yuyi 的御驿工具会自动挂载进 digital-twin 预设，分身会话即可经 Hub 通信；其
`node_modules\@deepseek-ai` 由 setup.ps1 统一为指向 DSH 运行时依赖的 junction，
避免双实例导致的御驿 Tab「未配置」/接口 404 问题（见 dsh-launcher v1.3.1 的说明）。