#!/usr/bin/env bash
#
# pi-bootstrap — 一键安装 Pi + 火山方舟 Agent Plan
#
# 用法（curl 管道）:
#   curl -fsSL https://raw.githubusercontent.com/glancers/pi-bootstrap/main/install.sh | bash
#
# 或者先下载再跑（支持环境变量控制）:
#   curl -fsSL -o install.sh https://raw.githubusercontent.com/glancers/pi-bootstrap/main/install.sh
#   bash install.sh
#
# 可选环境变量:
#   SKIP_NODE=1            跳过 Node 安装（假定 PATH 上已有 node >= 22.19）
#   SKIP_ARK=1             跳过 arkcli / Agent Plan 配置（仅装 pi）
#   SKIP_SKILLS=1          跳过 skills 安装
#   ARK_PROFILE_NAME=xxx   Agent Plan profile 名（默认 agent-plan_cn-beijing_personal）
#   WITH_MCP=1             给 pi 注入 Agent Plan 内置 MCP（豆包搜索 / dataPro / OpenViking）
#   ARK_API_KEY=ark-xxx    提供后跳过 SSO 登录，直接用 API Key 建 profile
#
# 设计目标：macOS / Linux，无需 sudo，所有东西装在 $HOME 下。
# 登录类操作（火山 SSO）必须人工完成，脚本会在对应步骤引导。

set -euo pipefail

# ---------- 常量 ----------
NODE_MIN_MAJOR=22
NODE_MIN_MINOR=19
NODE_BASE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pi-node"
NPM_GLOBAL_PREFIX="$HOME/.local/npm-global"
PI_SKILLS_DIR="$HOME/.pi/agent/skills"
AGENT_SKILLS_DIR="$HOME/.agents/skills"
ARK_PROFILE_NAME="${ARK_PROFILE_NAME:-agent-plan_cn-beijing_personal}"

PI_PKG="@earendil-works/pi-coding-agent"
ARK_PKG="@volcengine/ark-cli"

# ---------- 输出辅助 ----------
if [ -t 1 ]; then
  BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; CYAN='\033[36m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; RESET=''
fi

info()  { printf "${CYAN}==>${RESET} ${BOLD}%s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}  ✓${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}  !${RESET} %s\n" "$*"; }
err()   { printf "${RED}  ✗${RESET} %s\n" "$*" >&2; }
step()  { printf "\n${BOLD}── %s${RESET}\n" "$*"; }
die()   { err "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1，请先安装后重试"; }

# 交互式命令（登录/授权）必须从控制终端读输入。
# 脚本常以 `curl | bash` 运行，此时 stdin 是管道，不重定向会导致登录流程直接失败。
TTY_STREAM=/dev/null
if [ -r /dev/tty ]; then
  TTY_STREAM=/dev/tty
fi
# 用法：run_interactive <cmd> [args...]
run_interactive() { "$@" <"$TTY_STREAM"; }

# ---------- 环境探测 ----------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin) PLATFORM=darwin ;;
  Linux)  PLATFORM=linux ;;
  *) die "不支持的系统: $OS（仅支持 macOS / Linux）" ;;
esac
case "$ARCH" in
  arm64|aarch64) NODE_ARCH=arm64 ;;
  x86_64|amd64)  NODE_ARCH=x64 ;;
  *) die "不支持的 CPU 架构: $ARCH" ;;
esac

# ---------- Node 版本判断 ----------
node_new_enough() {
  command -v node >/dev/null 2>&1 || return 1
  local ver major minor
  ver="$(node -p 'process.versions.node' 2>/dev/null || echo 0)"
  major="${ver%%.*}"; local rest="${ver#*.}"; minor="${rest%%.*}"
  [ "${major:-0}" -gt "$NODE_MIN_MAJOR" ] && return 0
  [ "${major:-0}" -eq "$NODE_MIN_MAJOR" ] && [ "${minor:-0}" -ge "$NODE_MIN_MINOR" ] && return 0
  return 1
}

# ---------- 安装 standalone Node（与 pi 官方安装器同一布局）----------
install_standalone_node() {
  info "下载 Node.js ${NODE_MIN_MAJOR}.x standalone (${PLATFORM}-${NODE_ARCH}) …"
  need curl
  local tmp dist_base node_file node_dir
  tmp="$(mktemp -d)"
  dist_base="https://nodejs.org/dist/latest-v${NODE_MIN_MAJOR}.x"

  curl -fsSL "$dist_base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  node_file="$(awk -v suffix="-${PLATFORM}-${NODE_ARCH}.tar.xz" '
    index($2, "node-v") == 1 && substr($2, length($2)-length(suffix)+1) == suffix { print $2; exit }
  ' "$tmp/SHASUMS256.txt")"
  [ -n "$node_file" ] || die "找不到 ${PLATFORM}-${NODE_ARCH} 的 Node 二进制"

  curl -fL --progress-bar "$dist_base/$node_file" -o "$tmp/$node_file"
  awk -v f="$node_file" '$2 == f { print }' "$tmp/SHASUMS256.txt" > "$tmp/SHA.selected"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp" && sha256sum -c SHA.selected >/dev/null) || die "Node 下载校验失败"
  else
    (cd "$tmp" && shasum -a 256 -c SHA.selected >/dev/null) || die "Node 下载校验失败"
  fi

  mkdir -p "$NODE_BASE_DIR"
  node_dir="$NODE_BASE_DIR/${node_file%.tar.xz}"
  rm -rf "$node_dir"
  tar -xf "$tmp/$node_file" -C "$NODE_BASE_DIR"
  ln -sfn "$node_dir" "$NODE_BASE_DIR/current"
  rm -rf "$tmp"
  ok "Node 安装到 $node_dir"
}

# ---------- PATH 持久化 ----------
SHELL_PROFILE=""
detect_shell_profile() {
  case "${SHELL:-}" in
    */zsh) SHELL_PROFILE="${ZDOTDIR:-$HOME}/.zshrc" ;;
    *)
      [ -f "$HOME/.bashrc" ] && SHELL_PROFILE="$HOME/.bashrc" || SHELL_PROFILE="$HOME/.profile"
      ;;
  esac
}

# ============================================================
step "准备 Node.js（>= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR}）与 npm"

if node_new_enough; then
  ok "Node $(node -v) 已满足要求"
elif [ -x "$NODE_BASE_DIR/current/bin/node" ] && \
     PATH="$NODE_BASE_DIR/current/bin:$PATH" node_new_enough; then
  ok "复用已安装的 standalone Node（$NODE_BASE_DIR/current）"
elif [ "${SKIP_NODE:-}" = 1 ]; then
  die "SKIP_NODE=1 但 PATH 上没有 >= ${NODE_MIN_MAJOR}.${NODE_MIN_MINOR} 的 Node，请先安装"
else
  install_standalone_node
fi

# 让本次脚本后续命令能找到 node/npm（standalone 优先于旧系统 node）
[ -x "$NODE_BASE_DIR/current/bin/node" ] && PATH="$NODE_BASE_DIR/current/bin:$PATH"
export PATH
node_new_enough || die "Node 版本仍不满足要求"
ok "node $(node -v) / npm $(npm -v)"

step "配置 npm 全局目录（$NPM_GLOBAL_PREFIX，无需 sudo）"
mkdir -p "$NPM_GLOBAL_PREFIX/bin" "$NPM_GLOBAL_PREFIX/lib"
# 用环境变量而非 `npm config set prefix`，不污染用户全局 ~/.npmrc
export NPM_CONFIG_PREFIX="$NPM_GLOBAL_PREFIX"
PATH="$NPM_GLOBAL_PREFIX/bin:$PATH"
export PATH

detect_shell_profile
# 用一个标记行整体管理，避免重复执行时留下多段
if ! grep -Fq "# >>> pi-bootstrap >>>" "$SHELL_PROFILE" 2>/dev/null; then
  {
    printf '\n# >>> pi-bootstrap >>>\n'
    [ -x "$NODE_BASE_DIR/current/bin/node" ] && printf 'export PATH="%s/current/bin:$PATH"\n' "$NODE_BASE_DIR"
    printf 'export NPM_CONFIG_PREFIX="%s"\n' "$NPM_GLOBAL_PREFIX"
    printf 'export PATH="%s/bin:$PATH"\n' "$NPM_GLOBAL_PREFIX"
    printf 'export PATH="$HOME/.pi/bin:$PATH"\n'
    printf '# <<< pi-bootstrap <<<\n'
  } >> "$SHELL_PROFILE"
  ok "已写入环境变量到 $SHELL_PROFILE"
else
  ok "$SHELL_PROFILE 中已有 pi-bootstrap 配置，跳过"
fi

step "安装 pi"
if command -v pi >/dev/null 2>&1; then
  ok "pi 已存在：$(pi --version 2>/dev/null || echo '?')，执行更新"
  npm install -g --ignore-scripts "$PI_PKG@latest" >/dev/null 2>&1 || warn "pi 更新失败，沿用现有版本"
else
  npm install -g --ignore-scripts "$PI_PKG"
  ok "pi 安装完成：$(pi --version 2>/dev/null || echo '?')"
fi

if [ "${SKIP_ARK:-}" != 1 ]; then
  step "安装火山方舟 arkcli"
  npm install -g "$ARK_PKG"
  ok "arkcli $(arkcli --version 2>/dev/null || echo '?')"
else
  warn "SKIP_ARK=1，跳过 arkcli / Agent Plan"
fi

# ---------- Skills ----------
if [ "${SKIP_SKILLS:-}" != 1 ]; then
  step "安装 Agent Skills"
  mkdir -p "$PI_SKILLS_DIR" "$AGENT_SKILLS_DIR"

  if [ "${SKIP_ARK:-}" != 1 ]; then
    info "安装 arkcli-* skills 到 $PI_SKILLS_DIR …"
    # +connect 默认装到探测到的全部 agent，--path 显式兜底 pi 目录
    arkcli +connect --path "$PI_SKILLS_DIR" || warn "arkcli skills 安装失败，登录后可重试: arkcli +connect --path $PI_SKILLS_DIR"
    ok "arkcli skills 就绪"
  fi
else
  warn "SKIP_SKILLS=1，跳过 skills"
fi

# ---------- 交互式：火山 Agent Plan ----------
configure_ark() {
  step "配置火山方舟 Agent Plan（写入 pi model/provider）"

  if [ -n "${ARK_API_KEY:-}" ]; then
    info "使用提供的 ARK_API_KEY 建 profile，跳过 SSO"
    arkcli profile create \
      --type agent-plan \
      --region cn-beijing \
      --name "$ARK_PROFILE_NAME" \
      --default-api-key "$ARK_API_KEY" \
      --plan-tier medium \
      --no-interactive \
      --set-default || warn "profile 创建失败（可能已存在），继续尝试用现有 profile"
  else
    # 注意：auth status 在 SSO token 过期时也会失败，不能据此判断是否登录过。
    # 未登录态先尝试 whoami，失败才引导 SSO 登录。
    if ! arkcli auth whoami >/dev/null 2>&1; then
      cat <<'EOF'

  接下来需要登录火山方舟（浏览器 SSO）。
  终端会打开浏览器或给出链接，用你的火山引擎账号完成授权后回到这里。

EOF
      run_interactive arkcli auth login volc-sso || die "火山登录未完成"
    else
      ok "火山方舟已登录：$(arkcli auth whoami 2>/dev/null | head -1 || echo '?')"
    fi

    # 若目标 profile 不存在，引导创建
    if ! arkcli profile show --profile "$ARK_PROFILE_NAME" >/dev/null 2>&1; then
      info "创建 Agent Plan profile: $ARK_PROFILE_NAME"
      run_interactive arkcli profile create \
        --type agent-plan \
        --region cn-beijing \
        --name "$ARK_PROFILE_NAME" \
        --set-default || warn "profile 创建中断，可稍后手动: arkcli profile create --type agent-plan --set-default"
    fi
  fi

  local configure_args=(helper configure pi --profile "$ARK_PROFILE_NAME")
  [ "${WITH_MCP:-}" = 1 ] && configure_args+=(--with-mcp)

  info "写入 pi 配置：arkcli ${configure_args[*]}"
  arkcli "${configure_args[@]}" && ok "pi 已切到 Agent Plan" || warn "自动配置失败，可手动执行: arkcli ${configure_args[*]}"
}
[ "${SKIP_ARK:-}" != 1 ] && configure_ark || true

# ---------- 收尾 ----------
cat <<EOF

${GREEN}${BOLD}安装完成！${RESET}

${BOLD}下一步：${RESET}
  1. 让 PATH 在新终端生效：
       source "$SHELL_PROFILE"
  2. 启动 pi：
       pi
  3. 在 pi 内确认模型（默认应为 ark-code-latest / agent-plan）：
       /model

${BOLD}已安装：${RESET}
  - Node  $(node -v 2>/dev/null)        $([ -x "$NODE_BASE_DIR/current/bin/node" ] && echo "(standalone: $NODE_BASE_DIR/current)" || echo "(系统)")
  - pi    $(pi --version 2>/dev/null || echo '?')
  - npm global prefix: $NPM_GLOBAL_PREFIX
$(command -v arkcli >/dev/null 2>&1 && printf '  - arkcli %s\n' "$(arkcli --version 2>/dev/null || echo '?')")

${DIM}提示：火山登录态只保存在本机，不随脚本分发，每台新电脑都要各自登录一次。${RESET}
EOF
