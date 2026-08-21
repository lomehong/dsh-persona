@echo off
title 数字分身 (DSH)

rem 使用 dsh-persona 专用便携版 Node 运行时（与系统 Node 完全隔离）
set "PATH=%LOCALAPPDATA%\dsh-persona\node;%PATH%"

rem 检测 3080 是否已有服务在运行（例如桌面应用已启动），有则直接打开浏览器
powershell -NoProfile -Command "try{$null=Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:3080/';exit 0}catch{exit 1}"
if %errorlevel%==0 goto already_running

echo 正在启动数字分身（首次启动约需 10~30 秒）...
echo 就绪后浏览器会自动打开 http://127.0.0.1:3080
echo 关闭本窗口即停止数字分身。
echo.

rem 后台轮询端口，就绪后自动打开浏览器（最多等 60 秒）
start "" /b powershell -NoProfile -WindowStyle Hidden -Command "for($i=0;$i -lt 60;$i++){try{Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3080|Out-Null;Start-Process 'http://127.0.0.1:3080';break}catch{Start-Sleep 1}}"

dsh web

echo.
echo 数字分身已退出。
pause
exit /b 0

:already_running
echo 检测到数字分身已在运行（端口 3080 已被占用），直接打开浏览器。
start http://127.0.0.1:3080
echo.
pause
