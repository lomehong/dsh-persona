#!/usr/bin/env bash
# ── DSH 数字分身清理脚本 ────────────────────────────────────────────
# 用于重复安装/升级前清理旧的缓存和残留，全新 Mac 首次安装无需运行。
# 用法: ./scripts/cleanup.sh && ./scripts/setup.sh
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP_NAME="dsh-persona.app"
APP_PATH="$HOME/Applications/$APP_NAME"
TARGET_DIR="$(cd "$(dirname "$0")/.." && pwd)/app/src-tauri/target"

green() { printf "\033[32m✓ %s\033[0m\n" "$1"; }
yellow() { printf "\033[33m⚠ %s\033[0m\n" "$1"; }

echo "── DSH 数字分身 清理旧环境 ──"
echo

# 1. 停止运行中的 App
echo "1/7 停止运行中的 App…"
if pgrep -f "dsh-persona-app" >/dev/null 2>&1; then
  pkill -f "dsh-persona-app" 2>/dev/null || true
  sleep 1
  green "已停止"
else
  green "无运行中的进程"
fi

# 2. 注销 LaunchServices 旧记录（防止缓存残留）
echo "2/7 注销 LaunchServices 旧记录…"
if [[ -d "$APP_PATH" ]]; then
  "$LSREG" -u "$APP_PATH" 2>/dev/null && green "已注销 ~/Applications/$APP_NAME" || true
fi
# 注销 target/ 构建副本（如果存在）
BUNDLE_PATH="$TARGET_DIR/release/bundle/macos/$APP_NAME"
if [[ -d "$BUNDLE_PATH" ]]; then
  "$LSREG" -u "$BUNDLE_PATH" 2>/dev/null && green "已注销 target/ 构建副本" || true
fi

# 3. 删除旧 App
echo "3/7 删除旧 App…"
if [[ -d "$APP_PATH" ]]; then
  rm -rf "$APP_PATH" && green "已删除 ~/Applications/$APP_NAME"
else
  green "无旧 App"
fi

# 4. 删除构建缓存（防止 target/ 里的旧副本干扰）
echo "4/7 删除构建缓存…"
if [[ -d "$TARGET_DIR" ]]; then
  rm -rf "$TARGET_DIR" && green "已删除 target/"
else
  green "无构建缓存"
fi

# 5. 清除启动台数据库（SQLite 缓存在 /var/folders 下，killall Dock 清不掉）
echo "5/7 清除启动台缓存…"
LAUNCHPAD_DB="$(find /var/folders -path "*/com.apple.dock.launchpad/db" -type d 2>/dev/null | head -1)"
if [[ -n "$LAUNCHPAD_DB" ]]; then
  rm -f "$LAUNCHPAD_DB/db" "$LAUNCHPAD_DB/db-wal" "$LAUNCHPAD_DB/db-shm" 2>/dev/null && green "已删除启动台数据库" || yellow "启动台数据库删除失败（不影响安装）"
else
  green "无启动台数据库"
fi

# 6. 重启 Dock（让 Dock 重建启动台）
echo "6/7 重启 Dock…"
killall Dock 2>/dev/null && green "已重启 Dock" || yellow "Dock 重启失败（不影响安装）"

# 7. 等待 Dock 重建
sleep 2
green "Dock 已重建"

echo
echo "── 清理完成，可以运行 setup.sh ──"
