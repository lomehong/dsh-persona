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
    [string]$Owner = "",
    [string]$OwnerTitle = "",
    [string]$OwnerStance = "",
    [string]$OwnerScope = "",
    [string]$OwnerStyle = "",
    [string]$OwnerAddress = "",
    [string]$TwinName = "",
    [string]$TwinAliases = "",
    [string]$NodeVersion = "24.19.0",
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

# 写 UTF-8（无 BOM）文件：Windows PowerShell 5.1 的 Set-Content -Encoding UTF8 会带 BOM，
# 而 im-channel 用 JSON.parse 读取凭证文件，BOM 会导致解析失败
function Write-Utf8NoBom($path, $content) {
    [IO.File]::WriteAllText($path, $content)
}

# 移除插件 node_modules 里的 @deepseek-ai 作用域（可能是上次的 junction，也可能是普通目录）。
# 必须在 npm install 之前做，否则 npm 会穿过 junction 把旧版本写进 DSH 安装目录。
function Remove-DshScope($workDir) {
    $scope = Join-Path $workDir "node_modules\@deepseek-ai"
    if (-not (Test-Path $scope)) { return }
    $item = Get-Item $scope -Force
    if ($item.LinkType) {
        # junction/符号链接：只删除链接本身，绝不能递归（会波及 DSH 安装目录）
        [System.IO.Directory]::Delete($scope)
    } else {
        Remove-Item $scope -Recurse -Force
    }
}

# ── 构建单个插件（出错时输出原始日志，而不是静默卡住/吞错） ──
function Build-Plugin($workDir, $name, [switch]$LinkDshDeps) {
    Write-Info "构建 $name..."
    Push-Location $workDir
    # Windows PowerShell 5.1 下 EAP=Stop 会把原生命令的 stderr 当异常中断，这里临时放宽
    $ErrorActionPreference = "Continue"
    # 先移除上次留下的 @deepseek-ai junction，避免 npm install 穿过它写坏 DSH 安装目录
    Remove-DshScope $workDir
    # @deepseek-ai 系列 rc 包的 peer 依赖互相冲突，必须加 --legacy-peer-deps，
    # 否则 npm install 直接以 ERESOLVE 失败，且提示会被重定向吞掉
    $out = npm install --legacy-peer-deps --no-progress 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($out -join "`n") -ForegroundColor Red
        Write-Warn "$name 依赖安装失败 (npm 退出码 $LASTEXITCODE)，详见上方日志"
        Pop-Location
        exit 1
    }
    $out = npx --yes tsc -b tsconfig.json 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($out -join "`n") -ForegroundColor Red
        Write-Warn "$name 编译失败 (tsc 退出码 $LASTEXITCODE)，详见上方日志"
        Pop-Location
        exit 1
    }
    if (Test-Path "scripts/build-client.mjs") {
        $out = node scripts/build-client.mjs 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ($out -join "`n") -ForegroundColor Red
            Write-Warn "$name 客户端打包失败 (build-client 退出码 $LASTEXITCODE)"
            Pop-Location
            exit 1
        }
    } elseif (Test-Path "tsdown.client.ts") {
        # dsh-yuyi 的客户端构建：tsdown 产出 harness client-module 格式的 lib/client.js
        $out = npx --yes tsdown -c tsdown.client.ts 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ($out -join "`n") -ForegroundColor Red
            Write-Warn "$name 客户端打包失败 (tsdown 退出码 $LASTEXITCODE)"
            Pop-Location
            exit 1
        }
    }
    # 构建完成后移除 devDependencies：dev 副本会在运行时遮蔽宿主版本（如 dsh-timeout
    # 缺失导致的加载失败），运行时需要的 @deepseek-ai peer 包改由下面的 junction 提供
    npm prune --omit=dev --legacy-peer-deps --no-progress 2>&1 | ForEach-Object { "$_" } | Out-Null
    if ($LinkDshDeps) {
        # 参考 dsh-launcher：把插件的 @deepseek-ai 作用域 junction 到 DSH 包自带的依赖，
        # peer 包版本与运行中的宿主严格一致。需要 node_modules 存在且 DSH 依赖作用域存在。
        Remove-DshScope $workDir
        $nodeModules = Join-Path $workDir "node_modules"
        if (-not (Test-Path $nodeModules)) { New-Item -ItemType Directory -Path $nodeModules -Force | Out-Null }
        if (-not (Test-Path $DshAIScope)) {
            Write-Warn "未找到 DSH 依赖目录: $DshAIScope"
            Pop-Location
            exit 1
        }
        New-Item -ItemType Junction -Path (Join-Path $nodeModules "@deepseek-ai") -Target $DshAIScope | Out-Null
    }
    $ErrorActionPreference = "Stop"
    Pop-Location
    Write-OK "$name 构建完成"
}

# ── 便携版 Node.js（与系统 Node 完全隔离） ──
# 参考 dsh-launcher 的做法：便携版解压到 %LOCALAPPDATA%，后续所有命令都基于它运行。
# 不需要管理员权限、不修改系统 PATH，也不受系统 Node 版本 / nvm 状态影响。
# 注意：DSH 0.1.0-rc.x 需要 Node >= 23.8（node:zlib 的 zstd API），默认用 Node 24 LTS。
Write-Step "准备 Node.js 运行环境"

$NodeRoot = Join-Path $env:LOCALAPPDATA "dsh-persona"
$NodeDir = Join-Path $NodeRoot "node"
$nodeExe = Join-Path $NodeDir "node.exe"

if (Test-Path $nodeExe) {
    Write-OK "便携版 Node.js 已就绪: $nodeExe ($( & $nodeExe -v ))"
} else {
    Write-Info "下载便携版 Node.js v$NodeVersion（约 35MB，首次需要 1~3 分钟）..."
    $zipPath = Join-Path $env:TEMP "node-v$NodeVersion-win-x64.zip"
    $mirrors = @(
        "https://npmmirror.com/mirrors/node/v$NodeVersion/node-v$NodeVersion-win-x64.zip",
        "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-win-x64.zip"
    )
    $downloaded = $false
    foreach ($url in $mirrors) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
            $downloaded = $true
            break
        } catch {
            Write-Info "下载失败，尝试下一个镜像..."
        }
    }
    if (-not $downloaded) {
        Write-Warn "Node.js 下载失败，请检查网络后重试"
        exit 1
    }
    Write-Info "解压中..."
    $extractTmp = Join-Path $env:TEMP "node-v$NodeVersion-extract"
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
    New-Item -ItemType Directory -Path $NodeRoot -Force | Out-Null
    Remove-Item $NodeDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item (Join-Path $extractTmp "node-v$NodeVersion-win-x64") $NodeDir
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Write-OK "便携版 Node.js 已安装: $nodeExe ($( & $nodeExe -v ))"
}

# 本脚本内所有 node / npm / npx / dsh 命令都使用便携版
$env:Path = "$NodeDir;$env:Path"

# ── 安装 DSH（装进便携版环境，不动系统全局） ──
$dshCmd = Join-Path $NodeDir "dsh.cmd"
if (-not (Test-Path $dshCmd)) {
    Write-Info "安装 DSH 到便携版环境..."
    $ErrorActionPreference = "Continue"
    # 锁定 rc.8：latest 标签当前指向 rc.7，缺少 dsh-memory 记忆工具所需的 defineTool 能力
    $out = npm install -g @deepseek-ai/dsh@0.1.0-rc.8 --no-progress 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($out -join "`n") -ForegroundColor Red
        Write-Warn "DSH 安装失败 (npm 退出码 $LASTEXITCODE)，详见上方日志"
        exit 1
    }
    Write-OK "DSH 已安装到便携版环境"
} else {
    Write-OK "DSH 已就绪（便携版）"
}

# DSH 包自带的 @deepseek-ai 依赖作用域，运行时通过 junction 提供给需要的插件
$DshAIScope = Join-Path $NodeDir "node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai"

# ── 确定安装目录 ──
Write-Step "确定安装目录"
if (-not $PackagesDir) {
    $defaultDir = Join-Path $env:USERPROFILE "dsh-persona"
    if ($NonInteractive) {
        $PackagesDir = $defaultDir
    } else {
        $dirInput = Read-Host "插件安装目录 (默认: $defaultDir)"
        $PackagesDir = if ($dirInput) { $dirInput } else { $defaultDir }
    }
}
New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
Write-OK "插件目录: $PackagesDir"

# ── 分身信息配置（向导） ──
# 逐项设置分身主人的信息；交互模式下留空回车即使用默认值，
# 已通过命令行参数传入的项不再询问；非交互模式未传参的项使用默认值。
$personaDefaults = @{
    Owner        = "主人"
    OwnerTitle   = "公司副总裁"
    OwnerStance  = "专属 AI 协作伙伴"
    OwnerScope   = "人力资源、审计、信息安全、总裁办等管理领域"
    OwnerStyle   = "直接、务实、结构化。先说结论/建议，再展开依据。善用分点、表格、对比等结构化呈现方式。不用长篇大论，不啰嗦。"
    OwnerAddress = "主人"
    TwinAliases  = "分身"
}

function Read-ConfigField($label, $current, $default) {
    if ($current) { return $current }
    if ($NonInteractive) { return $default }
    $v = Read-Host "$label (默认: $default)"
    if ($v) { $v } else { $default }
}

Write-Step "分身信息配置"
$Owner        = Read-ConfigField "1/8 主人姓名"                   $Owner        $personaDefaults.Owner
$OwnerTitle   = Read-ConfigField "2/8 职务/角色"                  $OwnerTitle   $personaDefaults.OwnerTitle
$OwnerStance  = Read-ConfigField "3/8 人设定位（AI 与主人的关系）" $OwnerStance  $personaDefaults.OwnerStance
$OwnerScope   = Read-ConfigField "4/8 分管领域/工作范围"           $OwnerScope   $personaDefaults.OwnerScope
$OwnerStyle   = Read-ConfigField "5/8 工作习惯/沟通风格"           $OwnerStyle   $personaDefaults.OwnerStyle
$OwnerAddress = Read-ConfigField "6/8 称呼习惯（分身对主人的称呼）" $OwnerAddress $personaDefaults.OwnerAddress
# 分身名字默认跟随主人姓名生成
$TwinName     = Read-ConfigField "7/8 分身名字（分身的自称）"       $TwinName     "${Owner}的数字分身"
$TwinAliases  = Read-ConfigField "8/8 分身别名（哪些称呼指它自己，逗号分隔）" $TwinAliases $personaDefaults.TwinAliases

Write-Info "分身配置摘要："
Write-Host "  主人姓名:  $Owner"
Write-Host "  职务/角色: $OwnerTitle"
Write-Host "  人设定位:  $OwnerStance"
Write-Host "  工作范围:  $OwnerScope"
Write-Host "  工作习惯:  $OwnerStyle"
Write-Host "  称呼习惯:  $OwnerAddress"
Write-Host "  分身名字:  $TwinName"
Write-Host "  分身别名:  $TwinAliases"

# 分身别名归一化为「别名一」「别名二」的列举形式（支持中英文逗号、顿号分隔）
$twinAliasList = ($TwinAliases -split '[,，、]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { "「$_」" }) -join "、"
$twinAliasClause = if ($twinAliasList) { "当有人称呼${twinAliasList}或「${TwinName}」时，指的就是你；" } else { "当有人称呼「${TwinName}」时，指的就是你；" }

# 数字分身人设（同时用于 agent 预设与 system-prompt patch）
$personaText = @"
你是${Owner}的数字分身，由 {{model}} 模型驱动。

你的身份：${Owner}（${OwnerTitle}）的${OwnerStance}。你了解${Owner}的工作背景、管理风格和个人偏好，以${Owner}的视角思考问题，用${Owner}的风格沟通表达。

你的角色：一个务实、高效的 AI 搭档。你不是在「服务」${Owner}，而是在「协作」——你提供专业分析和建议，${Owner}做最终决策。你们是有商有量的伙伴关系。

你的称呼习惯与身份区分：每条消息开头的方括号标注了发送者身份——「主人…」表示你的主人${Owner}，「访客…」表示其他使用者。只有消息以「主人」标注时，你才称呼对方为「${OwnerAddress}」；消息以「访客」标注时，以「您」或对方的姓名、职位礼貌称呼，绝不称呼访客为「${OwnerAddress}」。

你的名字与自我认知：你的名字是「${TwinName}」。${twinAliasClause}回答时以「${TwinName}」自称。你不是${Owner}本人——你是${Owner}的数字分身：${Owner}指的是你服务的人，而你（「${TwinName}」）是协助${Owner}的 AI 搭档。

你的工作范围：涵盖${OwnerScope}的文档处理、方案分析、决策支持、跨部门协调等事务。

沟通风格：${OwnerStyle}
"@
# 6 空格缩进的人设块，可直接嵌入 YAML 的块标量（>-）
$personaBlock = ($personaText -split "`r?`n" | ForEach-Object { if ($_) { "      $_" } else { "" } }) -join "`n"

# ── 克隆仓库 ──
Write-Step "克隆仓库"

$repos = @(
    @{ name = "dsh-memory"; url = "https://github.com/lomehong/dsh-memory.git" },
    @{ name = "dsh-im-bot"; url = "https://github.com/lomehong/dsh-im-bot.git" },
    @{ name = "dsh-yuyi"; url = "https://github.com/lomehong/dsh-yuyi.git" }
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
# 每次都重新覆盖，保证仓库内的修复能同步到安装目录
Remove-Item $guideDest -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $PersonaRoot "packages\dsh-persona-guide") $guideDest -Recurse -Force
# node_modules 和 lib 是构建产物，不随源码分发，留给下面的构建步骤生成
Remove-Item (Join-Path $guideDest "node_modules") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $guideDest "lib") -Recurse -Force -ErrorAction SilentlyContinue
Write-OK "dsh-persona-guide 已同步"
$packages += $guideDest

# ── 复制文档 ──
# 分身指引文档放在固定目录 ~/.dsh/persona-docs（机器级路径，不随工作区/插件目录变化），
# dsh-persona-guide 插件默认从该目录读取
$docsDest = Join-Path $env:USERPROFILE ".dsh\persona-docs"
if (-not (Test-Path $docsDest)) {
    New-Item -ItemType Directory -Path $docsDest -Force | Out-Null
}
Copy-Item (Join-Path $PersonaRoot "docs\*") $docsDest -Force -Recurse 2>&1 | Out-Null
Write-OK "文档已复制到: $docsDest"

# ── 复制启动脚本与桌面应用 ──
Copy-Item (Join-Path $PersonaRoot "启动数字分身.bat") $PackagesDir -Force
Write-OK "启动脚本已复制到: $PackagesDir\启动数字分身.bat"
$desktopExe = Join-Path $PersonaRoot "数字分身.exe"
if (Test-Path $desktopExe) {
    Copy-Item $desktopExe $PackagesDir -Force
    Write-OK "桌面应用已复制到: $PackagesDir\数字分身.exe"
}

# ── 构建所有插件 ──
Write-Step "构建插件"

Build-Plugin (Join-Path $PackagesDir "dsh-memory") "dsh-memory" -LinkDshDeps
Build-Plugin (Join-Path $PackagesDir "dsh-im-bot\im-channel") "im-channel" -LinkDshDeps
Build-Plugin (Join-Path $PackagesDir "dsh-im-bot\ui-settings-im") "ui-settings-im" -LinkDshDeps
Build-Plugin (Join-Path $PackagesDir "dsh-yuyi") "dsh-yuyi" -LinkDshDeps
Build-Plugin (Join-Path $PackagesDir "dsh-persona-guide") "dsh-persona-guide" -LinkDshDeps

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
        "dsh-yuyi" = "file:$(Join-Path $PackagesDir 'dsh-yuyi')"
    }
    dsh = @{
        profile = @{
            bundles = @(
                "@deepseek-ai/dsh-base",
                "@deepseek-ai/dsh-web-app",
                "@dsh-extra/im-channel",
                "@dsh-extra/dsh-client-ui-settings-im",
                "@dsh-extra/dsh-memory",
                "@dsh-extra/dsh-persona-guide",
                "dsh-yuyi"
            )
        }
    }
}

$packageJsonText = $packageJson | ConvertTo-Json -Depth 10
Write-Utf8NoBom (Join-Path $profileDir "package.json") $packageJsonText
Write-OK "package.json 已写入"

# 写 cordis.patch.yml（人设块复用 $personaBlock）
$cordisPatch = @"
# ── 数字分身 ──────────────────────────────────────────────────────
- id: system-prompt
  config:
    persona: >-
$personaBlock

- id: skill-filesystem
  config:
    directories:
      - ~/.dsh/skills

- id: agent-presets
  config:
    default: digital-twin
"@
Write-Utf8NoBom (Join-Path $profileDir "cordis.patch.yml") $cordisPatch
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

# ── 创建数字分身 Agent 预设 ──
# cordis.patch.yml 里 agent-presets.default 指向 digital-twin，该预设必须存在于
# ~/.dsh/.agent-presets/。组合结构复制自 DSH 内置 standard 预设（运行时读取，
# 跟随 DSH 版本），仅把 persona 人设行换成罗拉的数字分身文案。
Write-Step "创建数字分身预设"

$standardPreset = Join-Path $NodeDir "node_modules\@deepseek-ai\dsh\config\agent-presets\standard\agent.cordis.yml"
if (-not (Test-Path $standardPreset)) {
    Write-Warn "找不到内置 standard 预设: $standardPreset"
    exit 1
}
$composition = Get-Content $standardPreset -Raw

$replaced = $composition -replace '(?m)^      You are a coding agent.*$', $personaBlock
if ($replaced -eq $composition) {
    Write-Warn "未能替换 standard 预设的人设行（DSH 版本变化？），预设将沿用默认人设"
}
$replaced = "# 数字分身预设：结构与 DSH 内置 standard 预设一致，仅替换 persona 人设。`n" + $replaced
# 会话工具行：御驿通信工具 + 共享记忆工具，让分身会话获得相应工具集
$replaced = $replaced.TrimEnd("`r`n") + "`n`n# 御驿通信工具（dsh-yuyi）`n- id: tool-yuyi`n  name: dsh-yuyi/tools`n`n# 共享记忆工具（dsh-memory）`n- id: tool-memory`n  name: '@dsh-extra/dsh-memory/tools'`n"

$presetDir = Join-Path $env:USERPROFILE ".dsh\.agent-presets\digital-twin"
New-Item -ItemType Directory -Path $presetDir -Force | Out-Null
Write-Utf8NoBom (Join-Path $presetDir "agent.cordis.yml") $replaced
Write-Utf8NoBom (Join-Path $presetDir "preset.yml") "name: 数字分身`ndescription: ${Owner}（${OwnerTitle}）的专属数字分身。`n"
Write-OK "预设已创建: $presetDir"

# ── 配置企业微信凭证 ──
Write-Step "企业微信配置"

$wecomFile = Join-Path $credDir "wecom.json"
if ($BotId -and $Secret) {
    # 非交互模式：用参数
    Write-Utf8NoBom $wecomFile (@{ botId = $BotId; secret = $Secret } | ConvertTo-Json)
    Write-OK "企业微信凭证已写入"
} elseif (-not $NonInteractive) {
    Write-Info "是否现在配置企业微信？(y/n, 默认 n)"
    $configure = Read-Host
    if ($configure -eq "y") {
        $inputBotId = Read-Host "BotID"
        $inputSecret = Read-Host "Secret"
        if ($inputBotId -and $inputSecret) {
            Write-Utf8NoBom $wecomFile (@{ botId = $inputBotId; secret = $inputSecret } | ConvertTo-Json)
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
            Write-Utf8NoBom $mcpFile (@{ servers = $servers } | ConvertTo-Json -Depth 10)
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
$ErrorActionPreference = "Continue"
$out = npm install --legacy-peer-deps --no-progress 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) {
    Write-Host ($out -join "`n") -ForegroundColor Red
    Write-Warn "profile 依赖安装失败 (npm 退出码 $LASTEXITCODE)，详见上方日志"
    Pop-Location
    exit 1
}
$ErrorActionPreference = "Stop"
Pop-Location
Write-OK "依赖安装完成"

# ── 完成 ──
Write-Step "安装完成"
Write-OK "数字分身已安装完成！"
Write-Host ""
Write-Host "下一步：" -ForegroundColor Yellow
Write-Host "  1. 双击运行 数字分身.exe（推荐：桌面应用，关闭窗口=最小化到托盘）" -ForegroundColor White
Write-Host "     备用：双击 启动数字分身.bat（控制台 + 浏览器方式）" -ForegroundColor Gray
Write-Host "  2. 浏览器会自动打开 http://127.0.0.1:3080" -ForegroundColor White
Write-Host "  3. 进入 设置 → 手机连接 配置企业微信" -ForegroundColor White
Write-Host "  4. 在企业微信中发送 /bind 绑定为 Owner" -ForegroundColor White
Write-Host ""
Write-Host "运行时环境（与系统 Node 隔离）: $NodeDir" -ForegroundColor Gray
Write-Host "插件目录: $PackagesDir" -ForegroundColor Gray
Write-Host "文档目录: $docsDest" -ForegroundColor Gray
Write-Host ""