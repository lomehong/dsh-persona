#!/usr/bin/env bash
#
# DSH 数字分身一键安装脚本（macOS / Linux 版）
# 与 setup.ps1（Windows）对等：便携版 Node、插件构建、digital-twin 预设、profile 配置。
# 差异：junction → symlink（无需管理员权限）；
#   macOS 运行时位于 ~/Library/Application Support/dsh-persona；
#   Linux 运行时位于 ~/.local/share/dsh-persona。
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
OS="$(uname)"
case "$OS" in
  Darwin) RUNTIME_ROOT="$HOME/Library/Application Support/dsh-persona" ;;
  Linux)  RUNTIME_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/dsh-persona" ;;
  *)      echo "  ⚠ 本脚本仅用于 macOS/Linux（Windows 请使用 scripts/setup.ps1）"; exit 1 ;;
esac
NODE_DIR="$RUNTIME_ROOT/node"
PROFILE_DIR="$HOME/.dsh/profiles/web"
DSH_AI_SCOPE="$NODE_DIR/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai"
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
  # nodejs.org 的包名用小写平台名（linux/darwin），uname 在 Linux 上返回大写
  PLAT="$(printf '%s' "$OS" | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"; case "$ARCH" in arm64|aarch64) ARCH="arm64" ;; *) ARCH="x64" ;; esac
  info "下载便携版 Node.js v$NODE_VERSION ($PLAT-$ARCH)…"
  ZIP="$TMPDIR/node-v$NODE_VERSION-$PLAT-$ARCH.tar.gz"
  MIRRORS=(
    "https://npmmirror.com/mirrors/node/v$NODE_VERSION/node-v$NODE_VERSION-$PLAT-$ARCH.tar.gz"
    "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-$PLAT-$ARCH.tar.gz"
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
  mv "$EXTRACT_TMP/node-v$NODE_VERSION-$PLAT-$ARCH" "$NODE_DIR"
  rm -rf "$EXTRACT_TMP" "$ZIP"
  ok "便携版 Node.js 已安装: $NODE_DIR/bin/node ($("$NODE_DIR/bin/node" -v))"
fi
export PATH="$NODE_DIR/bin:$PATH"

# ── 安装 DSH ──
step "安装 DSH（便携版环境）"
if [[ ! -f "$NODE_DIR/bin/dsh" ]]; then
  info "安装 DSH…"
  # 锁定 rc.8：latest 标签当前指向 rc.7，缺少 dsh-memory 记忆工具所需的 defineTool 能力
  npm install -g @deepseek-ai/dsh@0.1.0-rc.8 --no-progress >/dev/null
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

step "获取插件仓库"
# 优先 codeload tar.gz 下载（HTTPS 直连快、无需 git、绕开 git 协议被限的网络）；
# 已有 .git 的目录仍走 git pull 更新；下载失败回退 git clone。
fetch_repo() { # $1=name
  local dir="$PACKAGES_DIR/$1"
  if [[ -d "$dir/.git" ]]; then
    ok "$1 已存在（git），拉取最新代码"
    # 本地构建产物（lib/）会阻塞 pull：先尝试干净拉取，失败则丢弃本地改动重试
    if ! git -C "$dir" pull --ff-only >/dev/null 2>&1; then
      info "$1 拉取被本地改动阻塞，丢弃本地改动后重试"
      git -C "$dir" checkout -- . 2>/dev/null
      git -C "$dir" pull --ff-only >/dev/null 2>&1 || warn "$1 拉取失败，使用当前本地版本继续"
    fi
    return
  fi
  info "下载 $1（tar.gz）…"
  local tgz_dir ext tgz src d
  tgz_dir="$(mktemp -d)"; ext="$(mktemp -d)"; tgz="$tgz_dir/$1.tar.gz"; src=""
  if curl -fsSL --max-time 300 -o "$tgz" "https://codeload.github.com/lomehong/$1/tar.gz/refs/heads/main"; then
    tar -xzf "$tgz" -C "$ext"
    for d in "$ext"/*/; do
      [[ -f "$d/package.json" || -d "$d/im-channel" ]] && { src="${d%/}"; break; }
    done
    if [[ -z "$src" ]]; then
      warn "$1 安装包内容异常（未找到仓库根目录）"
      rm -rf "$tgz_dir" "$ext"; exit 1
    fi
    rm -rf "$dir"
    mv "$src" "$dir"
    rm -rf "$tgz_dir" "$ext"
    ok "$1 下载完成"
  else
    rm -rf "$tgz_dir" "$ext"
    info "$1 tar 下载失败，回退 git clone…"
    if ! git clone "https://github.com/lomehong/$1.git" "$dir"; then
      warn "$1 获取失败（tar 与 git 均未成功），请检查网络后重试"
      exit 1
    fi
    ok "$1 克隆完成"
  fi
}
fetch_repo dsh-memory
fetch_repo dsh-im-bot
fetch_repo dsh-yuyi

# ── 复制 dsh-persona-guide 与文档 ──
step "复制分身指引插件"
GUIDE_DEST="$PACKAGES_DIR/dsh-persona-guide"
rm -rf "$GUIDE_DEST"
cp -R "$PERSONA_ROOT/packages/dsh-persona-guide" "$GUIDE_DEST"
rm -rf "$GUIDE_DEST/node_modules" "$GUIDE_DEST/lib"
ok "dsh-persona-guide 已同步"

DOCS_DEST="$HOME/.dsh/persona-docs"
mkdir -p "$DOCS_DEST"
cp -R "$PERSONA_ROOT/docs/." "$DOCS_DEST/"
ok "文档已复制到: $DOCS_DEST"

# ── 构建插件 ──
# 与 Windows 版相同的注意事项：@deepseek-ai 系列 rc 包 peer 依赖冲突须 --legacy-peer-deps；
# 构建后 prune 掉 devDependencies，需要运行时 peer 的插件改用 symlink 指向 DSH 自带依赖。
build_plugin() { # $1=目录 $2=名称 $3=是否链接 DSH 依赖(1/0)
  # ${N:-} 兜底：规避 bash 3.2 在 set -u 下 local 多赋值报 unbound variable
  local dir="${1:-}" name="${2:-}" link="${3:-0}"
  [[ -n "$dir" && -n "$name" ]] || { warn "build_plugin 参数缺失: dir='$dir' name='$name'"; exit 1; }
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
build_plugin "$PACKAGES_DIR/dsh-memory" "dsh-memory" 1
build_plugin "$PACKAGES_DIR/dsh-im-bot/im-channel" "im-channel" 1
build_plugin "$PACKAGES_DIR/dsh-im-bot/ui-settings-im" "ui-settings-im" 1
build_plugin "$PACKAGES_DIR/dsh-yuyi" "dsh-yuyi" 1
build_plugin "$GUIDE_DEST" "dsh-persona-guide" 1

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

STANDARD_PRESET="$NODE_DIR/lib/node_modules/@deepseek-ai/dsh/config/agent-presets/standard/agent.cordis.yml"
[[ -f "$STANDARD_PRESET" ]] || { warn "找不到内置 standard 预设: $STANDARD_PRESET"; exit 1; }
PRESET_DIR="$HOME/.dsh/.agent-presets/digital-twin"
mkdir -p "$PRESET_DIR"
BLOCK_FILE="$TMPDIR/persona-block.txt"
printf '%s\n' "$PERSONA_BLOCK" > "$BLOCK_FILE"
awk 'BEGIN{done=0} /^      You are a coding agent/ && !done { while ((getline line < BLOCK) > 0) print line; done=1; next } {print}' BLOCK="$BLOCK_FILE" "$STANDARD_PRESET" \
  | { printf '# 数字分身预设：结构与 DSH 内置 standard 预设一致，仅替换 persona 人设。\n'; cat; printf '\n# 御驿通信工具（dsh-yuyi）\n- id: tool-yuyi\n  name: dsh-yuyi/tools\n\n# 共享记忆工具（dsh-memory）\n- id: tool-memory\n  name: '"'"'@dsh-extra/dsh-memory/tools'"'"'\n'; } \
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

# ── 启动器（Linux 无桌面应用，生成启动脚本；macOS 安装 .app） ──
step "安装启动器"
STARTER="$PACKAGES_DIR/start-persona.sh"
if [[ "$OS" == "Linux" ]]; then
  cat > "$STARTER" <<EOF
#!/usr/bin/env bash
# 数字分身启动器（Linux）：已运行则直接打开，否则后台拉起 dsh web 并打开浏览器
export PATH="$NODE_DIR/bin:\$PATH"
PORT=3080
if curl -sf "http://127.0.0.1:\$PORT/" >/dev/null 2>&1; then
  echo "数字分身已在运行: http://127.0.0.1:\$PORT"
  command -v xdg-open >/dev/null 2>&1 && xdg-open "http://127.0.0.1:\$PORT"
  exit 0
fi
( for i in \$(seq 1 60); do
    curl -sf "http://127.0.0.1:\$PORT/" >/dev/null 2>&1 && {
      command -v xdg-open >/dev/null 2>&1 && xdg-open "http://127.0.0.1:\$PORT"
      break
    }
    sleep 1
  done ) &
exec dsh web
EOF
  chmod +x "$STARTER"
  ok "启动器已生成: $STARTER（前台运行，Ctrl+C 停止）"
else
  APP_SRC_PREBUILT="$PERSONA_ROOT/dsh-persona.app"
  APP_BUNDLE="$PERSONA_ROOT/app/src-tauri/target/release/bundle/macos/dsh-persona.app"
  install_app() {
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/dsh-persona.app"
    ditto "$1" "$HOME/Applications/dsh-persona.app"
    ok "已安装到 ~/Applications/dsh-persona.app"
  }
  if [[ -d "$APP_SRC_PREBUILT" ]]; then
    install_app "$APP_SRC_PREBUILT"
  elif [[ -d "$APP_BUNDLE" ]]; then
    install_app "$APP_BUNDLE"
  elif command -v cargo >/dev/null 2>&1; then
    # 真机构建（最推荐的验证路径；需要 Xcode Command Line Tools）
    info "检测到 Rust 工具链，从源码构建桌面应用（约 5~10 分钟）…"
    if (cd "$PERSONA_ROOT/app/src-tauri" && npx --yes @tauri-apps/cli@latest build --bundles app); then
      [[ -d "$APP_BUNDLE" ]] && install_app "$APP_BUNDLE" || { warn "构建产物未找到，请检查上方日志"; }
    else
      warn "桌面应用构建失败（请确认已安装 Xcode Command Line Tools: xcode-select --install）"
    fi
  else
    info "未检测到 Rust 工具链，跳过桌面应用。可选：brew install rust 后重跑本脚本自动构建，或从 GitHub Actions Artifacts 下载"
  fi
fi

# ── 完成 ──
step "安装完成"
ok "数字分身已安装完成！"
echo
echo "下一步："
if [[ "$OS" == "Linux" ]]; then
  echo "  启动: $STARTER（前台运行，Ctrl+C 停止；自动打开浏览器）"
  echo "  或后台运行: nohup $STARTER > ~/.local/share/dsh-persona/dsh-web.log 2>&1 &"
else
  echo "  打开 ~/Applications/dsh-persona.app（或运行: dsh web）"
fi
echo "  首次使用：进入 设置 → 手机连接 配置企业微信，并在企业微信发送 /bind 绑定为 Owner"
echo
echo "运行时环境: $NODE_DIR"
echo "插件目录: $PACKAGES_DIR"
echo "文档目录: $DOCS_DEST"

# ── 立即启动（安装程序式体验：装完即用） ──
v=""
if ! $NON_INTERACTIVE; then
  read -r -p "是否立即启动数字分身？(Y/n, 默认 Y): " v
fi
if [[ -z "$v" || "$v" == "Y" || "$v" == "y" ]]; then
  if [[ "$OS" == "Darwin" && -d "$HOME/Applications/dsh-persona.app" ]]; then
    open "$HOME/Applications/dsh-persona.app"
    ok "已启动 dsh-persona.app"
  elif [[ "$OS" == "Linux" && -x "$STARTER" ]]; then
    nohup "$STARTER" > "$RUNTIME_ROOT/dsh-web.log" 2>&1 &
    ok "已在后台启动（日志: $RUNTIME_ROOT/dsh-web.log，停止: pkill -f 'dsh/lib/bin.js'）"
  else
    info "未找到启动器，可手动运行: dsh web"
  fi
fi
