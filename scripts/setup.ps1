#!/usr/bin/env pwsh
<#
.SYNOPSIS
  数字分身一键安装脚本
.DESCRIPTION
  自动克隆、构建、配置 DSH 数字分身所需的所有插件。
  支持交互式和非交互式两种模式。
#>

param(
    [string]$PackagesDir = "",
    [string]$BotId = "",
    [string]$Secret = "",
    [switch]$NonInteractive = $false
)

$ErrorActionPreference = "Stop"

# 脚本所在目录（dsh-persona 仓库根目录）
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PersonaRoot = Split-Path -Parent $ScriptRoot

# ── 颜色输出 ──
function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }

# ── 检测 DSH ──
Write-Step "检测环境"
$dshPath = Get-Command dsh -ErrorAction SilentlyContinue
if (-not $dshPath) {
    Write-Warn "DSH 未安装，请先安装 DSH (DeepSeek Harness)"
    exit 1
}
Write-OK "DSH 已安装: $($dshPath.Source)"

# ── 确定安装目录 ──
Write-Step "确定安装目录"
if (-not $PackagesDir) {
    $defaultDir = Join-Path $env:USERPROFILE "dsh-persona"
    if ($NonInteractive) {
        $PackagesDir = $defaultDir
    } else {
        $input = Read-Host "插件安装目录 (默认: $defaultDir)"
        $PackagesDir = if ($input) { $input } else { $defaultDir }
    }
}
New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
Write-OK "插件目录: $PackagesDir"

# ── 克隆仓库 ──
Write-Step "克隆仓库"

$repos = @(
    @{ name = "dsh-memory"; url = "https://github.com/lomehong/dsh-memory.git" },
    @{ name = "dsh-im-bot"; url = "https://github.com/lomehong/dsh-im-bot.git" }
)

$packages = @()

foreach ($repo in $repos) {
    $repoPath = Join-Path $PackagesDir $repo.name
    if (Test-Path (Join-Path $repoPath ".git")) {
        Write-OK "$($repo.name) 已存在，拉取最新代码"
        Push-Location $repoPath
        git pull --ff-only 2>&1 | Out-Null
        Pop-Location
    } else {
        Write-Info "克隆 $($repo.name)..."
        git clone $repo.url $repoPath 2>&1 | Out-Null
        Write-OK "$($repo.name) 克隆完成"
    }
    $packages += $repoPath
}

# ── 复制 dsh-persona-guide ──
Write-Step "复制分身指引插件"
$guideDest = Join-Path $PackagesDir "dsh-persona-guide"
if (Test-Path $guideDest) {
    Write-OK "dsh-persona-guide 已存在"
} else {
    Copy-Item (Join-Path $PersonaRoot "packages\dsh-persona-guide") $guideDest -Recurse -Force
    Write-OK "dsh-persona-guide 已复制"
}
$packages += $guideDest

# ── 复制文档 ──
$docsDest = Join-Path $PackagesDir "docs"
if (-not (Test-Path $docsDest)) {
    New-Item -ItemType Directory -Path $docsDest -Force | Out-Null
}
Copy-Item (Join-Path $PersonaRoot "docs\*") $docsDest -Force -Recurse 2>&1 | Out-Null
Write-OK "文档已复制到: $docsDest"

# ── 构建所有插件 ──
Write-Step "构建插件"

# 1. dsh-memory
Write-Info "构建 dsh-memory..."
Push-Location (Join-Path $PackagesDir "dsh-memory")
npm install 2>&1 | Out-Null
npx tsc -b tsconfig.json 2>&1 | Out-Null
if (Test-Path "scripts/build-client.mjs") {
    node scripts/build-client.mjs 2>&1 | Out-Null
}
Pop-Location
Write-OK "dsh-memory 构建完成"

# 2. im-channel
Write-Info "构建 im-channel..."
Push-Location (Join-Path $PackagesDir "dsh-im-bot\im-channel")
npm install 2>&1 | Out-Null
npx tsc -b tsconfig.json 2>&1 | Out-Null
Pop-Location
Write-OK "im-channel 构建完成"

# 3. ui-settings-im
Write-Info "构建 ui-settings-im..."
Push-Location (Join-Path $PackagesDir "dsh-im-bot\ui-settings-im")
npm install 2>&1 | Out-Null
npx tsc -b tsconfig.json 2>&1 | Out-Null
if (Test-Path "scripts/build-client.mjs") {
    node scripts/build-client.mjs 2>&1 | Out-Null
}
Pop-Location
Write-OK "ui-settings-im 构建完成"

# 4. dsh-persona-guide
Write-Info "构建 dsh-persona-guide..."
Push-Location (Join-Path $PackagesDir "dsh-persona-guide")
npm install 2>&1 | Out-Null
npx tsc -b tsconfig.json 2>&1 | Out-Null
if (Test-Path "scripts/build-client.mjs") {
    node scripts/build-client.mjs 2>&1 | Out-Null
}
Pop-Location
Write-OK "dsh-persona-guide 构建完成"

# ── 配置 DSH Profile ──
Write-Step "配置 DSH Profile"

$profileDir = Join-Path $env:USERPROFILE ".dsh\profiles\web"
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

# 写 package.json
$packageJson = @{
    name = "dsh-profile-web"
    private = $true
    dependencies = @{
        "@dsh-extra/im-channel" = "file:$(Join-Path $PackagesDir 'dsh-im-bot\im-channel')"
        "@dsh-extra/dsh-client-ui-settings-im" = "file:$(Join-Path $PackagesDir 'dsh-im-bot\ui-settings-im')"
        "@dsh-extra/dsh-memory" = "file:$(Join-Path $PackagesDir 'dsh-memory')"
        "@dsh-extra/dsh-persona-guide" = "file:$(Join-Path $PackagesDir 'dsh-persona-guide')"
    }
    dsh = @{
        profile = @{
            bundles = @(
                "@deepseek-ai/dsh-base",
                "@deepseek-ai/dsh-web-app",
                "@dsh-extra/im-channel",
                "@dsh-extra/dsh-client-ui-settings-im",
                "@dsh-extra/dsh-memory",
                "@dsh-extra/dsh-persona-guide"
            )
        }
    }
}

$packageJson | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $profileDir "package.json") -Encoding UTF8
Write-OK "package.json 已写入"

# 写 cordis.patch.yml
$cordisPatch = @"
# ── 数字分身 ──────────────────────────────────────────────────────
- id: system-prompt
  config:
    persona: >-
      你是罗拉的数字分身，由 {{model}} 模型驱动。

      你的身份：罗拉（公司副总裁）的专属 AI 协作伙伴。你了解她的工作背景、管理风格和个人偏好，以她的视角思考问题，用她的风格沟通表达。

      你的角色：一个务实、高效的 AI 搭档。你不是在「服务」罗拉，而是在「协作」——你提供专业分析和建议，她做最终决策。你们是有商有量的伙伴关系。

      你的工作范围：涵盖人力资源、审计、信息安全、总裁办等管理领域的文档处理、方案分析、决策支持、跨部门协调等事务。

      沟通风格：直接、务实、结构化。先说结论/建议，再展开依据。善用分点、表格、对比等结构化呈现方式。不用长篇大论，不啰嗦。

- id: skill-filesystem
  config:
    directories:
      - ~/.dsh/skills

- id: agent-presets
  config:
    default: digital-twin
"@
$cordisPatch | Set-Content (Join-Path $profileDir "cordis.patch.yml") -Encoding UTF8
Write-OK "cordis.patch.yml 已写入"

# ── 创建目录结构 ──
Write-Step "创建目录结构"

# skills
$skillsDir = Join-Path $env:USERPROFILE ".dsh\skills"
@("management", "personal", "templates") | ForEach-Object {
    New-Item -ItemType Directory -Path (Join-Path $skillsDir $_) -Force | Out-Null
}
Write-OK "技能目录已创建: $skillsDir"

# credentials
$credDir = Join-Path $env:USERPROFILE ".dsh\im-channel\credentials"
New-Item -ItemType Directory -Path $credDir -Force | Out-Null

# ── 配置企业微信凭证 ──
Write-Step "企业微信配置"

$wecomFile = Join-Path $credDir "wecom.json"
if ($BotId -and $Secret) {
    # 非交互模式：用参数
    @{ botId = $BotId; secret = $Secret } | ConvertTo-Json | Set-Content $wecomFile -Encoding UTF8
    Write-OK "企业微信凭证已写入"
} elseif (-not $NonInteractive) {
    Write-Info "是否现在配置企业微信？(y/n, 默认 n)"
    $configure = Read-Host
    if ($configure -eq "y") {
        $inputBotId = Read-Host "BotID"
        $inputSecret = Read-Host "Secret"
        if ($inputBotId -and $inputSecret) {
            @{ botId = $inputBotId; secret = $inputSecret } | ConvertTo-Json | Set-Content $wecomFile -Encoding UTF8
            Write-OK "企业微信凭证已保存"
        } else {
            Write-Warn "跳过企业微信配置，可在 DSH 设置页面中配置"
        }
    } else {
        Write-Info "跳过，可在 DSH 设置页面中配置"
    }
} else {
    Write-Info "跳过企业微信配置（未提供参数），可在 DSH 设置页面中配置"
}

# ── 配置 MCP 服务器 ──
Write-Step "MCP 服务器配置"

$mcpFile = Join-Path $credDir "mcp-servers.json"
if (-not $NonInteractive) {
    Write-Info "是否现在配置 MCP 服务器（企业微信工具）？(y/n, 默认 n)"
    $configureMcp = Read-Host
    if ($configureMcp -eq "y") {
        $servers = @()
        do {
            Write-Host "添加 MCP 服务器（留空结束）"
            $name = Read-Host "  名称 (如: 企业微信日程)"
            if (-not $name) { break }
            $url = Read-Host "  URL"
            if ($name -and $url) {
                $servers += @{
                    name = $name
                    type = "streamable-http"
                    url = $url
                    enabled = $true
                    id = "mcp_$(Get-Date -Format 'yyyyMMddHHmmss')_$(Get-Random -Maximum 99999)"
                }
            }
        } while ($true)
        if ($servers.Count -gt 0) {
            @{ servers = $servers } | ConvertTo-Json -Depth 10 | Set-Content $mcpFile -Encoding UTF8
            Write-OK "已保存 $($servers.Count) 个 MCP 服务器"
        } else {
            Write-Info "未配置 MCP 服务器，可在 DSH 设置页面中配置"
        }
    } else {
        Write-Info "跳过，可在 DSH 设置页面中配置"
    }
}

# ── 安装依赖到 profile ──
Write-Step "安装依赖"
Push-Location $profileDir
npm install 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn "npm install 可能有错误，请检查 npm 日志"
}
Pop-Location
Write-OK "依赖安装完成"

# ── 完成 ──
Write-Step "安装完成"
Write-OK "数字分身已安装完成！"
Write-Host ""
Write-Host "下一步：" -ForegroundColor Yellow
Write-Host "  1. 启动 DSH: dsh web" -ForegroundColor White
Write-Host "  2. 在浏览器打开 http://localhost:3080" -ForegroundColor White
Write-Host "  3. 进入 设置 → 手机连接 配置企业微信" -ForegroundColor White
Write-Host "  4. 在企业微信中发送 /bind 绑定为 Owner" -ForegroundColor White
Write-Host ""
Write-Host "插件目录: $PackagesDir" -ForegroundColor Gray
Write-Host "文档目录: $docsDest" -ForegroundColor Gray
Write-Host ""