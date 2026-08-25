@echo off
rem DSH 数字分身 — 一键安装（GUI 优先，命令行回退）
rem
rem 行为：
rem   1. 优先查找 dsh-persona-installer.exe（GUI 安装向导）
rem      - PATH 上的安装版（默认 %LOCALAPPDATA%\Programs\DSH Persona Installer\）
rem      - 仓库内开发构建（.\app\installer\target\release\）
rem      - 与本批处理同目录
rem   2. 找不到 GUI 时，回退到原来的 powershell scripts\setup.ps1 流程

setlocal
set "SCRIPT_DIR=%~dp0"

rem ── 候选 GUI 二进制路径（按优先级）──
set "GUI_EXE="
for %%P in ("%LOCALAPPDATA%\Programs\DSH Persona Installer\dsh-persona-installer.exe") do set "CAND=%%~fP"
if exist "%CAND%" set "GUI_EXE=%CAND%"

if not defined GUI_EXE if exist "%SCRIPT_DIR%app\installer\target\release\dsh-persona-installer.exe" set "GUI_EXE=%SCRIPT_DIR%app\installer\target\release\dsh-persona-installer.exe"

if not defined GUI_EXE if exist "%SCRIPT_DIR%dsh-persona-installer.exe" set "GUI_EXE=%SCRIPT_DIR%dsh-persona-installer.exe"

if defined GUI_EXE (
  echo 启动 DSH 数字分身 GUI 安装向导: "%GUI_EXE%"
  start "" "%GUI_EXE%"
  exit /b 0
)

rem ── 回退：原命令行安装 ──
echo 未找到 dsh-persona-installer.exe，回退到命令行安装...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\setup.ps1" %*
endlocal