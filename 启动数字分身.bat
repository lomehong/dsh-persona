@echo off
title 数字分身 (DSH)

rem 使用 dsh-persona 专用便携版 Node 运行时（与系统 Node 完全隔离）
set "PATH=%LOCALAPPDATA%\dsh-persona\node;%PATH%"

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
