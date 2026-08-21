# DSH 数字分身 一行命令安装
#
# 用法（在内网服务器托管本文件与仓库压缩包后）：
#   irm http://<服务器>/install.ps1 | iex
# 内网/私有仓库场景，先指定仓库压缩包地址再执行（仍是一行）：
#   $env:DSP_ZIP_URL='http://<服务器>/dsh-persona.zip'; irm http://<服务器>/install.ps1 | iex
#
# 不设置 DSP_ZIP_URL 时默认尝试 GitHub codeload（公开仓库可用）。
# 本脚本也在仓库根目录内，直接 .\install.ps1 运行时跳过下载直接进入安装。
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
