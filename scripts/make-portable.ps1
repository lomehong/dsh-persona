#!/usr/bin/env pwsh
<#
.SYNOPSIS
  DSH 数字分身便携包（U盘版）制作器
.DESCRIPTION
  在任意有网的 Windows 机器上生成完全自包含的便携目录并压 zip：
  - DSH-Desktop.exe（便携模式应用层，来自 dsh-desktop Release 的便携 zip）
  - Data/node        便携 Node + npm -g DSH
  - Data/home        DSH_HOME：预置 profile（6 个默认插件 vendored tgz 装配，零 junction/
                     零绝对路径符号链接）+ 分身文档/技能目录/凭证目录
  首次插入运行时由应用内向导补全人设（digital-twin 预设 + cordis.patch.yml）。
  幂等：重复执行会更新构建产物并重建包（Data/home 中的运行期状态不迁移，制作即全新）。
#>
param(
    [string]$OutDir = "",
    [string]$WorkDir = "",
    [string]$DshVersion = "0.1.1-rc.2",
    [string]$DesktopVersion = "0.1.4",
    [string]$NodeVersion = "24.19.0",
    [switch]$SkipBuild = $false
)

$ErrorActionPreference = "Stop"

# 空串参数回退默认值（CI 传参时空环境变量会以空串覆盖 param 默认值）
if (-not $DshVersion) { $DshVersion = "0.1.1-rc.2" }
if (-not $DesktopVersion) { $DesktopVersion = "0.1.4" }
if (-not $NodeVersion) { $NodeVersion = "24.19.0" }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PersonaRoot = Split-Path -Parent $ScriptRoot

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "  → $msg" -ForegroundColor Gray }

if (-not $OutDir) { $OutDir = Join-Path $PersonaRoot "dist-portable" }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP "dsh-portable-build" }
$PkgRoot = Join-Path $OutDir "DSH-Persona-Portable"

# ── 0. 前置检查 ──
Write-Step "环境检查"
foreach ($tool in @("git", "node", "npm")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Warn "缺少 $tool（制作机需要 git / Node.js / npm）"
        exit 1
    }
}
Write-OK "git / node / npm 可用"

# ── 1. 获取插件源码 ──
Write-Step "获取插件源码"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$repos = @(
    @{ name = "dsh-memory"; url = "https://github.com/lomehong/dsh-memory.git" },
    @{ name = "dsh-im-bot"; url = "https://github.com/lomehong/dsh-im-bot.git" },
    @{ name = "dsh-yuyi"; url = "https://github.com/lomehong/dsh-yuyi.git" },
    @{ name = "dsh-model-failover"; url = "https://github.com/lomehong/dsh-model-failover.git" }
)
$ErrorActionPreference = "Continue"
foreach ($repo in $repos) {
    $repoPath = Join-Path $WorkDir $repo.name
    if (Test-Path (Join-Path $repoPath ".git")) {
        Write-Info "$($repo.name) 已存在，拉取最新"
        Push-Location $repoPath
        git pull --ff-only 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            git checkout -- . 2>&1 | Out-Null
            git pull --ff-only 2>&1 | Out-Null
        }
        Pop-Location
    } else {
        git clone $repo.url $repoPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "$($repo.name) 克隆失败"; exit 1 }
    }
}
$ErrorActionPreference = "Stop"

# dsh-persona-guide：仓库内自带
$guideBuild = Join-Path $WorkDir "dsh-persona-guide"
Remove-Item $guideBuild -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $PersonaRoot "packages\dsh-persona-guide") $guideBuild -Recurse -Force
Remove-Item (Join-Path $guideBuild "node_modules") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $guideBuild "lib") -Recurse -Force -ErrorAction SilentlyContinue
Write-OK "插件源码就绪"

# ── 2. 构建插件并 npm pack ──
# 与 setup.ps1 的 Build-Plugin 相同流程，但最后不打 junction——打包只取 lib 等产物，
# 运行期 peer 依赖由 profile 级 node_modules 向上解析提供（免 junction 的关键）。
Write-Step "构建插件并打包 tgz"

$pluginDirs = @(
    @{ dir = Join-Path $WorkDir "dsh-memory"; name = "dsh-memory" },
    @{ dir = Join-Path $WorkDir "dsh-im-bot\im-channel"; name = "im-channel" },
    @{ dir = Join-Path $WorkDir "dsh-im-bot\ui-settings-im"; name = "ui-settings-im" },
    @{ dir = Join-Path $WorkDir "dsh-yuyi"; name = "dsh-yuyi" },
    @{ dir = Join-Path $WorkDir "dsh-model-failover"; name = "dsh-model-failover" },
    @{ dir = $guideBuild; name = "dsh-persona-guide" }
)
$vendorDir = Join-Path $PkgRoot "Data\home\profiles\web\vendor"
New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
Remove-Item "$vendorDir\*.tgz" -Force -ErrorAction SilentlyContinue

# 运行期 peer 依赖并集（从各插件 package.json 的 peerDependencies 汇总，
# 装到 profile 级 node_modules，插件按 Node 标准向上解析命中）
$peerUnion = @{}
# 插件包名 → vendor tgz 映射（pack 时在循环内收集；npm pack 会把 scope 展平进文件名）
$packedDeps = @{}

foreach ($plugin in $pluginDirs) {
    # 解析 package.json（[IO.File]::ReadAllText 默认 UTF-8：PS 5.1 的 Get-Content -Raw
    # 对无 BOM 文件按 ANSI 解码，中文 description 会乱码致 ConvertFrom-Json 失败）；
    # 同时汇总运行期 peer 依赖（装到 profile 级 node_modules，插件按 Node 标准向上解析命中）
    $pj = [IO.File]::ReadAllText((Join-Path $plugin.dir "package.json")) | ConvertFrom-Json
    if ($pj.peerDependencies) {
        foreach ($p in $pj.peerDependencies.PSObject.Properties) {
            if (-not $peerUnion.ContainsKey($p.Name)) { $peerUnion[$p.Name] = $p.Value }
        }
    }
    if (-not $SkipBuild) {
        Write-Info "构建 $($plugin.name)..."
        Push-Location $plugin.dir
        $ErrorActionPreference = "Continue"
        $nmScope = Join-Path $plugin.dir "node_modules\@deepseek-ai"
        if (Test-Path $nmScope) {
            $item = Get-Item $nmScope -Force
            if ($item.LinkType) { [System.IO.Directory]::Delete($nmScope) }
            else { Remove-Item $nmScope -Recurse -Force }
        }
        $out = npm install --legacy-peer-deps --no-progress 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor Red; Write-Warn "$($plugin.name) npm install 失败"; Pop-Location; exit 1 }
        $out = npx --yes tsc -b tsconfig.json 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor Red; Write-Warn "$($plugin.name) tsc 失败"; Pop-Location; exit 1 }
        if (Test-Path "scripts/build-client.mjs") {
            $out = node scripts/build-client.mjs 2>&1 | ForEach-Object { "$_" }
            if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor Red; Write-Warn "$($plugin.name) client 打包失败"; Pop-Location; exit 1 }
        } elseif (Test-Path "tsdown.client.ts") {
            $out = npx --yes tsdown -c tsdown.client.ts 2>&1 | ForEach-Object { "$_" }
            if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor Red; Write-Warn "$($plugin.name) client 打包失败"; Pop-Location; exit 1 }
        }
        # 去掉 devDependencies 减小包体；peer 依赖靠 profile 级提供
        npm prune --omit=dev --legacy-peer-deps --no-progress 2>&1 | Out-Null
        # npm pack 也在放宽区执行：npm 的 stderr notice（如 remind）在 EAP=Stop 下会被当作终止错误
        $packOut = npm pack --pack-destination $vendorDir 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Host ($packOut -join "`n") -ForegroundColor Red; Write-Warn "$($plugin.name) npm pack 失败"; Pop-Location; exit 1 }
        Pop-Location
        $ErrorActionPreference = "Stop"
        $tgz = Get-ChildItem $vendorDir -Filter "*.tgz" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $packedDeps[$pj.name] = "file:vendor/$($tgz.Name)"
        Write-OK "$($plugin.name) 已打包（$($tgz.Name)）"
    } else {
        # -SkipBuild：只 pack 不构建（构建产物已就绪）
        Push-Location $plugin.dir
        $ErrorActionPreference = "Continue"
        $packOut = npm pack --pack-destination $vendorDir 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Host ($packOut -join "`n") -ForegroundColor Red; Write-Warn "$($plugin.name) npm pack 失败"; Pop-Location; exit 1 }
        Pop-Location
        $ErrorActionPreference = "Stop"
        $tgz = Get-ChildItem $vendorDir -Filter "*.tgz" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $packedDeps[$pj.name] = "file:vendor/$($tgz.Name)"
        Write-OK "$($plugin.name) 已打包（$($tgz.Name)）"
    }
}
$peerList = $peerUnion.GetEnumerator() | Sort-Object Name
Write-Info "profile 级运行期 peer 依赖：$($peerList.ForEach({ "$($_.Key)@$($_.Value)" }) -join ', ')"

# ── 3. 装配 Data/node（便携 Node + DSH）──
Write-Step "装配便携运行时 Data/node"
$dataNode = Join-Path $PkgRoot "Data\node"
$nodeExe = Join-Path $dataNode "node.exe"
if (-not (Test-Path $nodeExe)) {
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
            $downloaded = $true; break
        } catch { Write-Info "下载失败，尝试下一个镜像..." }
    }
    if (-not $downloaded) { Write-Warn "Node.js 下载失败"; exit 1 }
    $extractTmp = Join-Path $env:TEMP "node-v$NodeVersion-portable-extract"
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force
    New-Item -ItemType Directory -Force -Path $dataNode | Out-Null
    Move-Item (Join-Path $extractTmp "node-v$NodeVersion-win-x64\*") $dataNode
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Write-OK "便携 Node v$NodeVersion 就绪"
} else {
    Write-OK "便携 Node 已存在（跳过下载）"
}
$dshBin = Join-Path $dataNode "node_modules\@deepseek-ai\dsh\lib\bin.js"
if (-not (Test-Path $dshBin)) {
    Write-Info "npm -g 安装 DSH v$DshVersion 到 Data/node..."
    $npmCmd = Join-Path $dataNode "npm.cmd"
    $ErrorActionPreference = "Continue"
    $out = & $npmCmd install -g "@deepseek-ai/dsh@$DshVersion" --prefix $dataNode --no-progress 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dshBin)) {
        Write-Host ($out -join "`n") -ForegroundColor Red
        Write-Warn "DSH 安装失败"
        exit 1
    }
    Write-OK "DSH v$DshVersion 已装入 Data/node"
} else {
    Write-OK "DSH 已存在（跳过安装）"
}

# ── 4. 装配 profile（vendored tgz + peer 依赖 → 全复制、可重定位）──
Write-Step "装配 Data/home/profiles/web"
$profileDir = Join-Path $PkgRoot "Data\home\profiles\web"

# 依赖表：插件 tgz（file: 相对路径，npm 解包复制）+ peer 并集
# 客户端注入族（@deepseek-ai/dsh-client-*、react）不装：它们由 web 前端宿主在客户端
# 模块加载时提供，服务端从不 require——安装版的 junction 作用域同样不含这些包。
# @deepseek-ai/* 服务端 peer 钉死为 Data/node 内 DSH 自带作用域的精确版本（与运行时
# 严格对齐；registry 上多为 rc 版本，宽松范围如 >=0.1.0 常无匹配）。
$deps = @{}
foreach ($k in $packedDeps.Keys) { $deps[$k] = $packedDeps[$k] }
$dshScopeNested = Join-Path $dataNode "node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai"
$dshScopeFlat = Join-Path $dataNode "node_modules\@deepseek-ai"
foreach ($peer in $peerList) {
    if ($peer.Key -match '^@deepseek-ai/dsh-client-' -or $peer.Key -eq 'react') { continue }
    $ver = $peer.Value
    if ($peer.Key.StartsWith("@deepseek-ai/")) {
        $leaf = $peer.Key -replace "^@deepseek-ai/", ""
        $pjPath = Join-Path $dshScopeNested (Join-Path $leaf "package.json")
        if (-not (Test-Path $pjPath)) { $pjPath = Join-Path $dshScopeFlat (Join-Path $leaf "package.json") }
        if (Test-Path $pjPath) {
            $ver = ([IO.File]::ReadAllText($pjPath) | ConvertFrom-Json).version
        } else {
            Write-Warn "$($peer.Key) 不在 DSH 作用域内，保留范围 $ver（registry 解析）"
        }
    }
    $deps[$peer.Key] = $ver
}

$packageJson = @{
    name = "dsh-profile-web-portable"
    private = $true
    dependencies = $deps
    dsh = @{
        profile = @{
            bundles = @(
                "@deepseek-ai/dsh-base",
                "@deepseek-ai/dsh-web-app",
                "@dsh-extra/im-channel",
                "@dsh-extra/dsh-client-ui-settings-im",
                "@dsh-extra/dsh-memory",
                "@dsh-extra/dsh-persona-guide",
                "dsh-yuyi",
                "@dsh-extra/dsh-model-failover"
            )
        }
    }
}
[IO.File]::WriteAllText((Join-Path $profileDir "package.json"), ($packageJson | ConvertTo-Json -Depth 10))
Write-OK "package.json 已写入（$($deps.Count) 个依赖：$($deps.Keys -join ', ')）"

# 安装：node_modules 全部为真实目录（tgz 解包复制 + registry 复制），换盘符/换目录不受影响。
# 每次清空重装：跨轮次残留的 node_modules 会让 npm 认为已就绪而跳过解包，
# 掩盖 vendor tgz 更新（曾导致 lib/ 缺失）
$env:Path = "$dataNode;$env:Path"
Push-Location $profileDir
Remove-Item (Join-Path $profileDir "node_modules") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $profileDir "package-lock.json") -Force -ErrorAction SilentlyContinue
$ErrorActionPreference = "Continue"
$out = npm install --legacy-peer-deps --no-progress 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n") -ForegroundColor Red; Write-Warn "profile 依赖安装失败"; Pop-Location; exit 1 }
Pop-Location

# 冗余校验：node_modules 内不允许存在任何链接（junction/symlink 都会破坏可重定位性）
$links = Get-ChildItem (Join-Path $profileDir "node_modules") -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.LinkType } | Select-Object -First 5
if ($links) {
    $links | ForEach-Object { Write-Warn "发现链接: $($_.FullName) [$($_.LinkType)]" }
    Write-Warn "node_modules 存在链接，便携包不可重定位——中止"
    exit 1
}
# 安全网：npm pack 按 files 字段出包，若插件漏列 cordis.patch.yml，安装副本缺文件会让
# dsh 启动时 overlay 加载失败（安装版 file: 目录依赖是 symlink 直读源目录，掩盖此问题）。
# 统一从源目录补拷到安装副本。
foreach ($plugin in $pluginDirs) {
    $srcPatch = Join-Path $plugin.dir "cordis.patch.yml"
    if (-not (Test-Path $srcPatch)) { continue }
    $srcPjName = ([IO.File]::ReadAllText((Join-Path $plugin.dir "package.json")) | ConvertFrom-Json).name
    $dstPatch = Join-Path $profileDir "node_modules\$($srcPjName -replace "/", "\")\cordis.patch.yml"
    if (-not (Test-Path $dstPatch)) {
        Copy-Item $srcPatch $dstPatch -Force
        Write-Warn "$srcPjName 的 files 字段漏列 cordis.patch.yml，已补拷到安装副本"
    }
}
Write-OK "profile 装配完成（无链接，全部真实目录）"

# ── 5. home 骨架：文档 / 技能目录 / 凭证目录 ──
Write-Step "装配 Data/home 骨架"
$homeDir = Join-Path $PkgRoot "Data\home"
$docsDest = Join-Path $homeDir "persona-docs"
New-Item -ItemType Directory -Force -Path $docsDest | Out-Null
Copy-Item (Join-Path $PersonaRoot "docs\*") $docsDest -Force -Recurse
foreach ($s in @("management", "personal", "templates")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $homeDir "skills\$s") | Out-Null
}
New-Item -ItemType Directory -Force -Path (Join-Path $homeDir "im-channel\credentials") | Out-Null
Write-OK "文档 / 技能 / 凭证目录就绪"

# ── 6. 应用层：下载 DSH Desktop 便携 zip ──
Write-Step "装配应用层（DSH Desktop v$DesktopVersion 便携 zip）"
$appExe = Join-Path $PkgRoot "DSH-Desktop.exe"
if (-not (Test-Path $appExe)) {
    $zipName = "DSH-Desktop_Portable_v${DesktopVersion}_x64.zip"
    $relPath = "lomehong/dsh-desktop/releases/download/v$DesktopVersion/$zipName"
    $appZip = Join-Path $env:TEMP $zipName
    $mirrors = @(
        "https://github.com/$relPath",
        "https://ghfast.top/https://github.com/$relPath"
    )
    $downloaded = $false
    foreach ($url in $mirrors) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $appZip -UseBasicParsing
            $downloaded = $true; break
        } catch { Write-Info "下载失败，尝试下一个镜像..." }
    }
    if (-not $downloaded) { Write-Warn "DSH Desktop 便携 zip 下载失败（确认 v$DesktopVersion Release 已发布）"; exit 1 }
    $extractTmp = Join-Path $env:TEMP "dsh-desktop-portable-extract"
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $appZip -DestinationPath $extractTmp -Force
    # zip 内顶层为 DSH-Desktop/（或直接是文件）——统一铺到包根
    $inner = Get-ChildItem $extractTmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName "DSH-Desktop.exe") } | Select-Object -First 1
    $src = if ($inner) { $inner.FullName } else { $extractTmp }
    Copy-Item "$src\*" $PkgRoot -Recurse -Force
    Remove-Item $extractTmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $appZip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $appExe)) { Write-Warn "便携 zip 内容异常（未找到 DSH-Desktop.exe）"; exit 1 }
    Write-OK "DSH Desktop 应用文件已就位"
} else {
    Write-OK "DSH Desktop 已存在（跳过下载）"
}

# 启动便捷入口 + 说明文件
$batContent = "@echo off`r`nrem 数字分身便携版启动入口：等价于双击 DSH-Desktop.exe`r`nstart `"`" `"%~dp0DSH-Desktop.exe`"`r`n"
[IO.File]::WriteAllText((Join-Path $PkgRoot "启动数字分身.bat"), $batContent)

$readme = @"
DSH 数字分身 · 便携版说明
==========================

【使用】
1. 把整个 DSH-Persona-Portable 目录拷到U盘（建议USB 3.0 以上）或任意本机目录
2. 双击 DSH-Desktop.exe（或 启动数字分身.bat）
3. 首次运行会弹出「分身信息配置」向导：填写主人姓名/职务等信息后保存并启动；
   企业微信凭证可选，也可之后在 设置 → 手机连接 里配置
4. 关闭窗口 = 最小化到托盘（企业微信/御驿不中断）；托盘右键 → 退出 才真正结束

【数据在哪】
全部状态都在本目录 Data\home 里（会话、记忆、企业微信绑定、模型切换配置）。
换电脑/换盘符直接整目录拷走即可，无需任何导出。

【升级】
- 托盘「升级 DSH 运行时」：联网就地升级 Data\node 内的 DSH
- 完整升级：在任意有网电脑重新运行 make-portable.ps1 生成新包，
  把新包的 Data\home 覆盖回旧位置即保留全部状态

【安全须知】
企业微信凭证与全部会话记录明文保存在U盘上——U盘丢失等于分身身份丢失。
建议使用带硬件加密的U盘，或对重要凭证及时轮换。

【限制】
- 需要宿主机有 WebView2 运行时（Windows 11 / 已更新的 Windows 10 自带）
- 同一台电脑上「便携版」与「安装版」不能同时运行
- 桌面较旧（无 WebView2）时窗口无法创建：安装 WebView2 Runtime 后即可
"@
[IO.File]::WriteAllText((Join-Path $PkgRoot "README-便携版.txt"), $readme)
Write-OK "启动入口与说明文件已写入"

# ── 7. 打 zip ──
Write-Step "压缩便携包"
$zipOut = Join-Path $OutDir "DSH-Persona-Portable_v${DesktopVersion}_win-x64.zip"
Remove-Item $zipOut -Force -ErrorAction SilentlyContinue
# 用 Windows 自带 bsdtar（tar -a 按扩展名自动 zip）：PS 5.1 的 Compress-Archive
# 处理不了 node_modules 里的超长路径（mistralai 的深度嵌套 .d.ts 超 260 字符）。
# 显式全路径调用：PATH 上的 Git Bash GNU tar 会把 "F:" 解析成远程主机而失败。
$bsdtar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $bsdtar)) { Write-Warn "未找到 Windows bsdtar: $bsdtar"; exit 1 }
$ErrorActionPreference = "Continue"
$tarOut = & $bsdtar -a -c -f $zipOut -C $OutDir "DSH-Persona-Portable" 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipOut)) {
    Write-Host ($tarOut -join "`n") -ForegroundColor Red
    Write-Warn "便携包压缩失败"
    exit 1
}
$sizeMB = [math]::Round((Get-Item $zipOut).Length / 1MB, 1)
Write-OK "便携包: $zipOut ($sizeMB MB)"

Write-Step "完成"
Write-Host ""
Write-Host "便携目录: $PkgRoot" -ForegroundColor White
Write-Host "便携包:   $zipOut ($sizeMB MB)" -ForegroundColor White
Write-Host "拷贝整个 DSH-Persona-Portable 目录到U盘即可使用；首次运行走应用内分身向导" -ForegroundColor Gray
