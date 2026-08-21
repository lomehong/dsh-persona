# DSH digital-persona one-line installer
#
# Standard usage (public repo, target machine can reach GitHub):
#   irm https://raw.githubusercontent.com/lomehong/dsh-persona/main/install.ps1 | iex
#
# Private repo / intranet: host this file and the repo zip on any HTTP server
# (build the zip with: git archive --format=zip --prefix=dsh-persona-main/ -o dsh-persona.zip HEAD),
# then run on the target machine (still one line):
#   $env:DSP_ZIP_URL='http://<server>/dsh-persona.zip'; irm http://<server>/install.ps1 | iex
#
# Without DSP_ZIP_URL the repo zip is fetched from GitHub codeload (public repos).
# Running .\install.ps1 inside the repo skips download and goes straight to setup.
# Unattended: $env:DSP_SETUP_ARGS='-NonInteractive -Owner <name> -OwnerTitle <title>'
#
# NOTE: this file must stay pure ASCII -- PS 5.1 `irm | iex` may decode the
# response with the local codepage, and non-ASCII bytes can corrupt the script.
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host ""
Write-Host "=== DSH digital-persona : one-line install ===" -ForegroundColor Cyan
Write-Host ""

$Root    = Join-Path $env:USERPROFILE "dsh-persona"
$RepoDir = Join-Path $Root "dsh-persona"

function Get-ZipUrl {
    if ($env:DSP_ZIP_URL) { return $env:DSP_ZIP_URL }
    return "https://codeload.github.com/lomehong/dsh-persona/zip/refs/heads/main"
}

# running inside the repo: skip download, go straight to setup
$setupPath = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "scripts\setup.ps1"))) {
    $setupPath = Join-Path $PSScriptRoot "scripts\setup.ps1"
} else {
    $zipUrl = Get-ZipUrl
    $zipFile = Join-Path $env:TEMP "dsh-persona-install.zip"
    Write-Host "  -> downloading package: $zipUrl" -ForegroundColor Gray
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing

    Write-Host "  -> extracting..." -ForegroundColor Gray
    $extractDir = Join-Path $env:TEMP "dsh-persona-install-extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

    # accept both layouts: codeload zip has a dsh-persona-main/ prefix,
    # a local git archive may not; locate the repo root by scripts\setup.ps1
    $repoSource = $null
    if (Test-Path (Join-Path $extractDir "scripts\setup.ps1")) {
        $repoSource = $extractDir
    } else {
        $inner = Get-ChildItem $extractDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName "scripts\setup.ps1") } | Select-Object -First 1
        if ($inner) { $repoSource = $inner.FullName }
    }
    if (-not $repoSource) { Write-Host "  [X] package invalid (scripts\setup.ps1 not found)" -ForegroundColor Red; exit 1 }

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    if (Test-Path $RepoDir) { Remove-Item $RepoDir -Recurse -Force }
    Move-Item $repoSource $RepoDir
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipFile -Force -ErrorAction SilentlyContinue

    $setupPath = Join-Path $RepoDir "scripts\setup.ps1"
}

if (-not (Test-Path $setupPath)) {
    Write-Host "  [X] setup.ps1 not found, package may be incomplete" -ForegroundColor Red
    exit 1
}

Write-Host "  [OK] package ready, entering setup wizard (press Enter for defaults)" -ForegroundColor Green
Write-Host ""
# NOTE: array splatting binds positionally only; named args need full-string re-parse
if ($env:DSP_SETUP_ARGS) {
    Invoke-Expression "& `"$setupPath`" $env:DSP_SETUP_ARGS"
} else {
    & $setupPath
}
