#!/usr/bin/env bash
#
# DSH 数字分身 — 一键安装（macOS，GUI 优先，命令行回退）
#
# 候选位置（按优先级）：
#   1) ~/Applications/DSH Persona Installer.app
#   2) 仓库内 app/installer/target/release/bundle/macos/DSH Persona Installer.app
#   3) 仓库内 app/installer/target/release/dsh-persona-installer
# 全部找不到时回退到原 bash scripts/setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATES=(
  "$HOME/Applications/DSH Persona Installer.app"
  "$SCRIPT_DIR/app/installer/target/release/bundle/macos/DSH Persona Installer.app"
  "$SCRIPT_DIR/app/installer/target/release/dsh-persona-installer"
)

for c in "${CANDIDATES[@]}"; do
  if [[ -e "$c" ]]; then
    echo "启动 DSH 数字分身 GUI 安装向导: $c"
    if [[ "$c" == *.app ]]; then
      open "$c"
    else
      "$c" &
    fi
    exit 0
  fi
done

echo "未找到 dsh-persona-installer，回退到命令行安装..."
exec bash "$SCRIPT_DIR/scripts/setup.sh" "$@"