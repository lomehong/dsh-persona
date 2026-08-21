#!/usr/bin/env bash
#
# DSH 数字分身一键安装器（macOS）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/lomehong/dsh-persona/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --non-interactive --owner "张三" --owner-title "首席技术官"
#
# 私有部署：
#   curl -fsSL http://<服务器>/install.sh | DSP_ZIP_URL=http://<服务器>/dsh-persona.zip bash
#
set -eo pipefail

ZIP_URL="${DSP_ZIP_URL:-https://codeload.github.com/lomehong/dsh-persona/zip/refs/heads/main}"
INSTALL_DIR="$HOME/dsh-persona"
REPO_DIR="$INSTALL_DIR/dsh-persona"

# ── 本地检测：已在仓库内则直接转交 setup.sh ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-install.sh}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/scripts/setup.sh" ]]; then
  exec bash "$SCRIPT_DIR/scripts/setup.sh" "$@" < /dev/tty
fi

echo "=== DSH 数字分身安装器 ==="
echo

# ── 下载 ──
ZIP="$TMPDIR/dsh-persona-install.zip"
EXTRACT="$TMPDIR/dsh-persona-install-extract"

echo "→ 下载安装包…"
if ! curl -fsSL --max-time 300 -o "$ZIP" "$ZIP_URL"; then
  echo "⚠ 下载失败，请检查网络后重试"
  echo "  如果是私有仓库，请设置 DSP_ZIP_URL 环境变量"
  exit 1
fi

# ── 解压 ──
echo "→ 解压中…"
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
tar -xzf "$ZIP" -C "$EXTRACT"

# ── 定位仓库根（兼容 codeload 和 git archive 两种 zip 布局） ──
SRC=""
for d in "$EXTRACT" "$EXTRACT"/*/; do
  [[ -f "$d/scripts/setup.sh" ]] && SRC="$d" && break
done
if [[ -z "$SRC" ]]; then
  echo "⚠ 安装包无效（未找到 scripts/setup.sh）"
  exit 1
fi

# ── 落位 ──
mkdir -p "$INSTALL_DIR"
rm -rf "$REPO_DIR"
mv "$SRC" "$REPO_DIR"
rm -rf "$EXTRACT" "$ZIP"

echo "✓ 安装包就绪，进入配置向导"
echo

# ── 转交 setup.sh ──
# 关键：stdin 重接 TTY，否则 curl|bash 场景下交互式 read 会读到 EOF
exec bash "$REPO_DIR/scripts/setup.sh" "$@" < /dev/tty
