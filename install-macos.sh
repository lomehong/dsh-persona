#!/usr/bin/env bash
#
# DSH 数字分身一键安装器（macOS）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/lomehong/dsh-persona/main/install-macos.sh | bash
#
set -eo pipefail

ZIP_URL="${DSP_ZIP_URL:-https://codeload.github.com/lomehong/dsh-persona/zip/refs/heads/main}"
INSTALL_DIR="$HOME/dsh-persona"
REPO_DIR="$INSTALL_DIR/dsh-persona"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-install-macos.sh}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/scripts/setup.sh" ]]; then
  exec bash "$SCRIPT_DIR/scripts/setup.sh" "$@" < /dev/tty
fi

echo "=== DSH 数字分身安装器（macOS）==="
echo

ZIP="$TMPDIR/dsh-persona-install.zip"
EXTRACT="$TMPDIR/dsh-persona-install-extract"

echo "→ 下载安装包…"
if ! curl -fsSL --max-time 300 -o "$ZIP" "$ZIP_URL"; then
  echo "⚠ 下载失败，请检查网络后重试"
  exit 1
fi

echo "→ 解压中…"
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
tar -xzf "$ZIP" -C "$EXTRACT"

SRC=""
for d in "$EXTRACT" "$EXTRACT"/*/; do
  [[ -f "$d/scripts/setup.sh" ]] && SRC="$d" && break
done
if [[ -z "$SRC" ]]; then
  echo "⚠ 安装包无效（未找到 scripts/setup.sh）"
  exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$REPO_DIR"
mv "$SRC" "$REPO_DIR"
rm -rf "$EXTRACT" "$ZIP"

echo "✓ 安装包就绪，进入配置向导"
exec bash "$REPO_DIR/scripts/setup.sh" "$@" < /dev/tty
