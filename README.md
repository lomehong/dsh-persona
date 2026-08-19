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

可选参数（分身主人信息，不传时默认为「罗拉 / 公司副总裁」，交互模式下也会提示输入）：

```powershell
.\scripts\setup.ps1 -BotId "你的BotID" -Secret "你的Secret" -Owner "张三" -OwnerTitle "首席技术官"
```

安装完成后，双击仓库根目录（或插件目录）的 **`启动数字分身.bat`** 启动，浏览器会自动打开
http://127.0.0.1:3080。关闭该窗口即停止数字分身。

## 仓库

- [dsh-memory](https://github.com/lomehong/dsh-memory) — 共享记忆插件
- [dsh-im-bot](https://github.com/lomehong/dsh-im-bot) — 企业微信通道、MCP 工具注册