# 🤖 罗拉数字分身

DSH (DeepSeek Harness) 数字分身插件包，包含一键部署所需的所有组件。

## 组件

```
dsh-persona/
├── packages/
│   └── dsh-persona-guide/     # 分身指引插件（对话 Tab）
├── scripts/
│   └── setup.ps1              # 一键安装脚本
├── docs/
│   ├── 数字分身搭建框架.md      # 分身搭建方法论
│   └── 数字分身部署指南.md      # 手动部署步骤
└── package.json
```

## 依赖

| 仓库 | 用途 |
|------|------|
| [dsh-im-bot](https://github.com/lomehong/dsh-im-bot) | 企业微信通道、MCP 工具注册 |
| [dsh-memory](https://github.com/lomehong/dsh-memory) | 共享记忆插件 |

## 一键安装

```powershell
# 克隆本仓库
git clone https://github.com/lomehong/dsh-persona.git
cd dsh-persona

# 运行安装脚本（交互式，会引导配置）
.\scripts\setup.ps1

# 或者非交互式
.\scripts\setup.ps1 -BotId "你的BotID" -Secret "你的Secret"
```

安装完成后启动 DSH：

```bash
dsh web
```

## 手动安装

详见 [部署指南](docs/数字分身部署指南.md)。

## 分身框架

详见 [搭建框架](docs/数字分身搭建框架.md)。