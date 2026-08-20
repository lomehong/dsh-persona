#!/usr/bin/env bash
#
# DSH 数字分身一键安装脚本（macOS 版）
# 与 setup.ps1（Windows）对等：便携版 Node、插件构建、digital-twin 预设、profile 配置。
# 差异：junction → symlink（无需管理员权限）、运行时位于 ~/Library/Application Support。
#
set -euo pipefail

# ── 默认值 ──
OWNER="" OWNER_TITLE="" OWNER_STANCE="" OWNER_SCOPE="" OWNER_STYLE="" OWNER_ADDRESS=""
TWIN_NAME="" TWIN_ALIASES=""
BOT_ID="" SECRET=""
PACKAGES_DIR=""
NON_INTERACTIVE=false
NODE_VERSION="24.19.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSONA_ROOT="$(dirname "$SCRIPT_DIR")"
RUNTIME_ROOT="$HOME/Library/Application Support/dsh-persona"
NODE_DIR="$RUNTIME_ROOT/node"
PROFILE_DIR="$HOME/.dsh/profiles/web"
DSH_AI_SCOPE="$NODE_DIR/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai"
[[ -n "${TMPDIR:-}" ]] || TMPDIR="/tmp"

# ── 参数解析 ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --owner-title) OWNER_TITLE="$2"; shift 2 ;;
    --owner-stance) OWNER_STANCE="$2"; shift 2 ;;
    --owner-scope) OWNER_SCOPE="$2"; shift 2 ;;
    --owner-style) OWNER_STYLE="$2"; shift 2 ;;
    --owner-address) OWNER_ADDRESS="$2"; shift 2 ;;
    --twin-name) TWIN_NAME="$2"; shift 2 ;;
    --twin-aliases) TWIN_ALIASES="$2"; shift 2 ;;
    --bot-id) BOT_ID="$2"; shift 2 ;;
    --secret) SECRET="$2"; shift 2 ;;
    --packages-dir) PACKAGES_DIR="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    *) echo "未知参数: $1（用法见 README）"; exit 1 ;;
  esac
done

step()  { printf '\n=== %s ===\n' "$1"; }
ok()    { printf '  ✓ %s\n' "$1"; }
info()  { printf '  → %s\n' "$1"; }
warn()  { printf '  ⚠ %s\n' "$1"; }

[[ "$(uname)" == "Darwin" ]] || { warn "本脚本仅用于 macOS（Windows 请使用 scripts/setup.ps1）"; exit 1; }

# ── 分身信息配置（向导） ──
read_field() { # $1=标签 $2=当前值 $3=默认值
  local label="$1" current="$2" default="$3" v
  if [[ -n "$current" ]]; then printf '%s' "$current"; return; fi
  if $NON_INTERACTIVE; then printf '%s' "$default"; return; fi
  read -r -p "$label (默认: $default): " v
  printf '%s' "${v:-$default}"
}

step "分身信息配置"
OWNER="$(read_field "1/8 主人姓名" "$OWNER" "主人")"
OWNER_TITLE="$(read_field "2/8 职务/角色" "$OWNER_TITLE" "公司副总裁")"
OWNER_STANCE="$(read_field "3/8 人设定位（AI 与主人的关系）" "$OWNER_STANCE" "专属 AI 协作伙伴")"
OWNER_SCOPE="$(read_field "4/8 分管领域/工作范围" "$OWNER_SCOPE" "人力资源、审计、信息安全、总裁办等管理领域")"
OWNER_STYLE="$(read_field "5/8 工作习惯/沟通风格" "$OWNER_STYLE" "直接、务实、结构化。先说结论/建议，再展开依据。善用分点、表格、对比等结构化呈现方式。不用长篇大论，不啰嗦。")"
OWNER_ADDRESS="$(read_field "6/8 称呼习惯（分身对主人的称呼）" "$OWNER_ADDRESS" "主人")"
TWIN_NAME="$(read_field "7/8 分身名字（分身的自称）" "$TWIN_NAME" "${OWNER}的数字分身")"
TWIN_ALIASES="$(read_field "8/8 分身别名（哪些称呼指它自己，逗号分隔）" "$TWIN_ALIASES" "分身")"

info "分身配置摘要："
printf '  主人姓名:  %s\n  职务/角色: %s\n  人设定位:  %s\n  工作范围:  %s\n  工作习惯:  %s\n  称呼习惯:  %s\n  分身名字:  %s\n  分身别名:  %s\n' \
  "$OWNER" "$OWNER_TITLE" "$OWNER_STANCE" "$OWNER_SCOPE" "$OWNER_STYLE" "$OWNER_ADDRESS" "$TWIN_NAME" "$TWIN_ALIASES"

# 别名归一化为「别名一」「别名二」列举（支持中英文逗号、顿号）
ALIAS_LIST="$(printf '%s' "$TWIN_ALIASES" | tr '，、' ',,' | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sed 's/^/「/;s/$/」/' | tr '\n' '、' | sed 's/、$//')"
if [[ -n "$ALIAS_LIST" ]]; then
  ALIAS_CLAUSE="当有人称呼${ALIAS_LIST}或「${TWIN_NAME}」时，指的就是你；"
else
  ALIAS_CLAUSE="当有人称呼「${TWIN_NAME}」时，指的就是你；"
fi

PERSONA_TEXT="你是${OWNER}的数字分身，由 {{model}} 模型驱动。

你的身份：${OWNER}（${OWNER_TITLE}）的${OWNER_STANCE}。你了解${OWNER}的工作背景、管理风格和个人偏好，以${OWNER}的视角思考问题，用${OWNER}的风格沟通表达。

你的角色：一个务实、高效的 AI 搭档。你不是在「服务」${OWNER}，而是在「协作」——你提供专业分析和建议，${OWNER}做最终决策。你们是有商有量的伙伴关系。

你的称呼习惯与身份区分：每条消息开头的方括号标注了发送者身份——「主人…」表示你的主人${OWNER}，「访客…」表示其他使用者。只有消息以「主人」标注时，你才称呼对方为「${OWNER_ADDRESS}」；消息以「访客」标注时，以「您」或对方的姓名、职位礼貌称呼，绝不称呼访客为「${OWNER_ADDRESS}」。

你的名字与自我认知：你的名字是「${TWIN_NAME}」。${ALIAS_CLAUSE}回答时以「${TWIN_NAME}」自称。你不是${OWNER}本人——你是${OWNER}的数字分身：${OWNER}指的是你服务的人，而你（「${TWIN_NAME}」）是协助${OWNER}的 AI 搭档。

你的工作范围：涵盖${OWNER_SCOPE}的文档处理、方案分析、决策支持、跨部门协调等事务。

沟通风格：${OWNER_STYLE}"

# ── 便携版 Node.js ──
step "准备 Node.js 运行环境"
if [[ -x "$NODE_DIR/bin/node" ]]; then
  ok "便携版 Node.js 已就绪: $NODE_DIR/bin/node ($("$NODE_DIR/bin/node" -v))"
else
  ARCH="$(uname -m)"; [[ "$ARCH" == "arm64" ]] || ARCH="x64"
  info "下载便携版 Node.js v$NODE_VERSION (darwin-$ARCH)…"
  ZIP="$TMPDIR/node-v$NODE_VERSION-darwin-$ARCH.tar.gz"
  MIRRORS=(
    "https://npmmirror.com/mirrors/node/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$ARCH.tar.gz"
    "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-$ARCH.tar.gz"
  )
  DOWNLOADED=false
  for URL in "${MIRRORS[@]}"; do
    if curl -fsSL --max-time 300 -o "$ZIP" "$URL"; then DOWNLOADED=true; break; fi
    info "下载失败，尝试下一个镜像…"
  done
  $DOWNLOADED || { warn "Node.js 下载失败，请检查网络后重试"; exit 1; }
  info "解压中…"
  EXTRACT_TMP="$TMPDIR/node-v$NODE_VERSION-extract"
  rm -rf "$EXTRACT_TMP"; mkdir -p "$EXTRACT_TMP"
  tar -xzf "$ZIP" -C "$EXTRACT_TMP"
  mkdir -p "$RUNTIME_ROOT"
  rm -rf "$NODE_DIR"
  mv "$EXTRACT_TMP/node-v$NODE_VERSION-darwin-$ARCH" "$NODE_DIR"
  rm -rf "$EXTRACT_TMP" "$ZIP"
  ok "便携版 Node.js 已安装: $NODE_DIR/bin/node ($("$NODE_DIR/bin/node" -v))"
fi
export PATH="$NODE_DIR/bin:$PATH"

# ── 安装 DSH ──
step "安装 DSH（便携版环境）"
if [[ ! -f "$NODE_DIR/bin/dsh" ]]; then
  info "安装 DSH…"
  npm install -g @deepseek-ai/dsh --no-progress >/dev/null
  [[ -f "$NODE_DIR/bin/dsh" ]] || { warn "DSH 安装失败"; exit 1; }
  ok "DSH 已安装到便携版环境"
else
  ok "DSH 已就绪（便携版）"
fi

# ── 安装目录与克隆 ──
step "确定安装目录"
[[ -n "$PACKAGES_DIR" ]] || PACKAGES_DIR="$HOME/dsh-persona"
if ! $NON_INTERACTIVE; then
  v=""
  read -r -p "插件安装目录 (默认: $PACKAGES_DIR): " v
  [[ -n "$v" ]] && PACKAGES_DIR="$v"
fi
mkdir -p "$PACKAGES_DIR"
ok "插件目录: $PACKAGES_DIR"

step "克隆仓库"
clone_or_pull() { # $1=name $2=url
  local dir="$PACKAGES_DIR/$1"
  if [[ -d "$dir/.git" ]]; then
    ok "$1 已存在，拉取最新代码"
    git -C "$dir" pull --ff-only >/dev/null 2>&1 || true
  else
    info "克隆 $1…"
    git clone "$2" "$dir" >/dev/null 2>&1
    ok "$1 克隆完成"
  fi
}
clone_or_pull dsh-memory "https://github.com/lomehong/dsh-memory.git"
clone_or_pull dsh-im-bot  "https://github.com/lomehong/dsh-im-bot.git"
clone_or_pull dsh-yuyi    "https://github.com/lomehong/dsh-yuyi.git"

# ── 复制 dsh-persona-guide 与文档 ──
step "复制分身指引插件"
GUIDE_DEST="$PACKAGES_DIR/dsh-persona-guide"
rm -rf "$GUIDE_DEST"
ditto "$PERSONA_ROOT/packages/dsh-persona-guide" "$GUIDE_DEST"
rm -rf "$GUIDE_DEST/node_modules" "$GUIDE_DEST/lib"
ok "dsh-persona-guide 已同步"

DOCS_DEST="$HOME/.dsh/persona-docs"
mkdir -p "$DOCS_DEST"
ditto "$PERSONA_ROOT/docs" "$DOCS_DEST"
ok "文档已复制到: $DOCS_DEST"

# ── 构建插件 ──
# 与 Windows 版相同的注意事项：@deepseek-ai 系列 rc 包 peer 依赖冲突须 --legacy-peer-deps；
# 构建后 prune 掉 devDependencies，需要运行时 peer 的插件改用 symlink 指向 DSH 自带依赖。
build_plugin() { # $1=目录 $2=名称 $3=是否链接 DSH 依赖(1/0)
  local dir="$1" name="$2" link="${3:-0}"
  info "构建 $name…"
  (
    cd "$dir"
    [[ -e node_modules/@deepseek-ai || -L node_modules/@deepseek-ai ]] && rm -rf node_modules/@deepseek-ai
    npm install --legacy-peer-deps --no-progress >/dev/null
    npx --yes tsc -b tsconfig.json >/dev/null
    [[ -f scripts/build-client.mjs ]] && node scripts/build-client.mjs >/dev/null
    [[ -f tsdown.client.ts ]] && npx --yes tsdown -c tsdown.client.ts >/dev/null
    npm prune --omit=dev --legacy-peer-deps --no-progress >/dev/null
  ) || { warn "$name 构建失败，请查看上方日志"; exit 1; }
  if [[ "$link" == "1" ]]; then
    rm -rf "$dir/node_modules/@deepseek-ai"
    mkdir -p "$dir/node_modules"
    [[ -d "$DSH_AI_SCOPE" ]] || { warn "未找到 DSH 依赖目录: $DSH_AI_SCOPE"; exit 1; }
    ln -s "$DSH_AI_SCOPE" "$dir/node_modules/@deepseek-ai"
  fi
  ok "$name 构建完成"
}

step "构建插件"
build_plugin "$PACKAGES_DIR/dsh-memory" "dsh-memory" 0
build_plugin "$PACKAGES_DIR/dsh-im-bot/im-channel" "im-channel" 1
build_plugin "$PACKAGES_DIR/dsh-im-bot/ui-settings-im" "ui-settings-im" 0
build_plugin "$PACKAGES_DIR/dsh-yuyi" "dsh-yuyi" 1
build_plugin "$GUIDE_DEST" "dsh-persona-guide" 0

# ── 配置 Profile ──
step "配置 DSH Profile"
mkdir -p "$PROFILE_DIR"
cat > "$PROFILE_DIR/package.json" <<EOF
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {
    "@dsh-extra/im-channel": "file:$PACKAGES_DIR/dsh-im-bot/im-channel",
    "@dsh-extra/dsh-client-ui-settings-im": "file:$PACKAGES_DIR/dsh-im-bot/ui-settings-im",
    "@dsh-extra/dsh-memory": "file:$PACKAGES_DIR/dsh-memory",
    "@dsh-extra/dsh-persona-guide": "file:$PACKAGES_DIR/dsh-persona-guide",
    "dsh-yuyi": "file:$PACKAGES_DIR/dsh-yuyi"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app",
        "@dsh-extra/im-channel",
        "@dsh-extra/dsh-client-ui-settings-im",
        "@dsh-extra/dsh-memory",
        "@dsh-extra/dsh-persona-guide",
        "dsh-yuyi"
      ]
    }
  }
}
EOF
ok "package.json 已写入"

# 人设块（6 空格缩进）嵌入 patch
PERSONA_BLOCK="$(printf '%s\n' "$PERSONA_TEXT" | sed 's/^[[:space:]]*$/!/;s/^/      /;s/^      !$//')"
cat > "$PROFILE_DIR/cordis.patch.yml" <<EOF
# ── 数字分身 ──────────────────────────────────────────────────────
- id: system-prompt
  config:
    persona: >-
${PERSONA_BLOCK}

- id: skill-filesystem
  config:
    directories:
      - ~/.dsh/skills

- id: agent-presets
  config:
    default: digital-twin
EOF
ok "cordis.patch.yml 已写入"

# ── 目录结构 / 预设 / 凭证 ──
step "创建目录结构与数字分身预设"
mkdir -p "$HOME/.dsh/skills/management" "$HOME/.dsh/skills/personal" "$HOME/.dsh/skills/templates"
mkdir -p "$HOME/.dsh/im-channel/credentials"
ok "技能与凭证目录已创建"

STANDARD_PRESET="$NODE_DIR/node_modules/@deepseek-ai/dsh/config/agent-presets/standard/agent.cordis.yml"
[[ -f "$STANDARD_PRESET" ]] || { warn "找不到内置 standard 预设: $STANDARD_PRESET"; exit 1; }
PRESET_DIR="$HOME/.dsh/.agent-presets/digital-twin"
mkdir -p "$PRESET_DIR"
BLOCK_FILE="$TMPDIR/persona-block.txt"
printf '%s\n' "$PERSONA_BLOCK" > "$BLOCK_FILE"
awk 'BEGIN{done=0} /^      You are a coding agent/ && !done { while ((getline line < BLOCK) > 0) print line; done=1; next } {print}' BLOCK="$BLOCK_FILE" "$STANDARD_PRESET" \
  | { printf '# 数字分身预设：结构与 DSH 内置 standard 预设一致，仅替换 persona 人设。\n'; cat; printf '\n# 御驿通信工具（dsh-yuyi）\n- id: tool-yuyi\n  name: dsh-yuyi/tools\n'; } \
  > "$PRESET_DIR/agent.cordis.yml"
rm -f "$BLOCK_FILE"
printf 'name: 数字分身\ndescription: %s（%s）的专属数字分身。\n' "$OWNER" "$OWNER_TITLE" > "$PRESET_DIR/preset.yml"
ok "预设已创建: $PRESET_DIR"

if [[ -n "$BOT_ID" && -n "$SECRET" ]]; then
  printf '{\n  "botId": "%s",\n  "secret": "%s"\n}\n' "$BOT_ID" "$SECRET" > "$HOME/.dsh/im-channel/credentials/wecom.json"
  ok "企业微信凭证已写入"
fi

# ── 安装 profile 依赖 ──
step "安装依赖"
(cd "$PROFILE_DIR" && npm install --legacy-peer-deps --no-progress >/dev/null) || { warn "profile 依赖安装失败"; exit 1; }
ok "依赖安装完成"

# ── 桌面应用 ──
step "安装桌面应用"
if [[ -d "$PERSONA_ROOT/数字分身.app" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/数字分身.app"
  ditto "$PERSONA_ROOT/数字分身.app" "$HOME/Applications/数字分身.app"
  ok "已安装到 ~/Applications/数字分身.app"
else
  info "仓库内暂无 macOS 应用包（数字分身.app），可从 GitHub Releases 下载后放入仓库根目录重跑本脚本，或直接使用 dsh web"
fi

# ── 完成 ──
step "安装完成"
ok "数字分身已安装完成！"
echo
echo "下一步："
echo "  1. 打开 ~/Applications/数字分身.app（或运行: dsh web）"
echo "  2. 浏览器访问 http://127.0.0.1:3080（App 模式自动打开）"
echo "  3. 进入 设置 → 手机连接 配置企业微信"
echo "  4. 在企业微信中发送 /bind 绑定为 Owner"
echo
echo "运行时环境: $NODE_DIR"
echo "插件目录: $PACKAGES_DIR"
echo "文档目录: $DOCS_DEST"
