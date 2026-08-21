@echo off
title 数字分身 - 一键安装

echo ================================================
echo   数字分身 一键安装程序
echo   完整安装 + 自动创建桌面快捷方式 + 装完即启动
echo ================================================
echo.
echo 安装过程约需 3~10 分钟（首次需下载运行时与构建插件），
echo 过程中会逐步询问分身信息，每项直接回车即用默认值。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup.ps1" %*
if %errorlevel% neq 0 (
  echo.
  echo 安装过程中出现错误，请查看上方日志后重试。
  pause
  exit /b 1
)

echo.
echo 安装流程结束，感谢使用。
pause
