# DSH 数字分身 一行命令安装
#
# 标准用法（仓库为 Public 时，目标机器可直连 GitHub）：
#   irm https://raw.githubusercontent.com/lomehong/dsh-persona/main/install.ps1 | iex
#
# 私有仓库 / 内网场景：在任意 HTTP 服务器托管本文件与仓库 zip
# （git archive --format=zip --prefix=dsh-persona-main/ -o dsh-persona.zip HEAD），
# 目标机器执行（仍是一行）：
#   $env:DSP_ZIP_URL='http://<服务器>/dsh-persona.zip'; irm http://<服务器>/install.ps1 | iex
#
# 不设置 DSP_ZIP_URL 时默认从 GitHub codeload 拉取（公开仓库可用）。
# 本脚本也在仓库根目录内，直接 .\install.ps1 运行时跳过下载直接进入安装。
# 无人值守：$env:DSP_SETUP_ARGS='-NonInteractive -Owner 甲子 -OwnerTitle 信息安全负责人'
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host ""
Write-Host "=== DSH 数字分身 · 一行命令安装 ===" -ForegroundColor Cyan
Write-Host ""

$Root    = Join-Path $env:USERPROFILE "dsh-persona"
$RepoDir = Join-Path $Root "dsh-persona"

function Get-ZipUrl {
    if ($env:DSP_ZIP_URL) { return $env:DSP_ZIP_URL }
    return "https://codeload.github.com/lomehong/dsh-persona/zip/refs/heads/main"
}

# 仓库内直接运行（.\install.ps1）：跳过下载直接进入 setup
$setupPath = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "scripts\setup.ps1"))) {
    $setupPath = Join-Path $PSScriptRoot "scripts\setup.ps1"
} else {
    $zipUrl = Get-ZipUrl
    $zipFile = Join-Path $env:TEMP "dsh-persona-install.zip"
    Write-Host "  → 下载安装包: $zipUrl" -ForegroundColor Gray
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing

    Write-Host "  → 解压中…" -ForegroundColor Gray
    $extractDir = Join-Path $env:TEMP "dsh-persona-install-extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

    # 兼容两种打包：GitHub codeload 带 dsh-persona-main/ 顶层目录；git archive 本地包可能无前缀
    $repoSource = $null
    if (Test-Path (Join-Path $extractDir "scripts\setup.ps1")) {
        $repoSource = $extractDir
    } else {
        $inner = Get-ChildItem $extractDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName "scripts\setup.ps1") } | Select-Object -First 1
        if ($inner) { $repoSource = $inner.FullName }
    }
    if (-not $repoSource) { Write-Host "  ✗ 安装包内容异常（未找到 scripts\setup.ps1）" -ForegroundColor Red; exit 1 }

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    if (Test-Path $RepoDir) { Remove-Item $RepoDir -Recurse -Force }
    Move-Item $repoSource $RepoDir
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue

    $setupPath = Join-Path $RepoDir "scripts\setup.ps1"
}

if (-not (Test-Path $setupPath)) {
    Write-Host "  ✗ 未找到 setup.ps1，安装包可能不完整" -ForegroundColor Red
    exit 1
}

Write-Host "  ✓ 安装包就绪，进入安装向导（每项直接回车用默认值）" -ForegroundColor Green
Write-Host ""
# 无人值守/自动化：$env:DSP_SETUP_ARGS='-NonInteractive -Owner 甲子 …' 可透传参数给 setup.ps1
# 注意：数组展开只按位置绑定参数，命名参数必须整串重新解析（Invoke-Expression）
if ($env:DSP_SETUP_ARGS) {
    Invoke-Expression "& `"$setupPath`" $env:DSP_SETUP_ARGS"
} else {
    & $setupPath
}
