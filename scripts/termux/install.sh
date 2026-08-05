#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

REPO_URL="${CODEX_PROXY_REPO_URL:-${CODEX_PROXY_REPO:-https://github.com/wmdhs12138/codex-proxy.git}}"
BRANCH="${CODEX_PROXY_BRANCH:-termux-aarch64}"
APP_DIR="${CODEX_PROXY_APP_DIR:-${CODEX_PROXY_DIR:-$HOME/projects/codex-proxy}}"
PORT="${CODEX_PROXY_PORT:-8080}"
CONFIG_DIR="${CODEX_PROXY_CONFIG_DIR:-$HOME/.config/codex-proxy-termux}"
BIN_DIR="${CODEX_PROXY_BIN_DIR:-$HOME/.local/bin}"
SESSION="${CODEX_PROXY_SESSION:-codex-proxy}"

info() { printf '[INFO] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

pkg update -y
pkg install -y git python clang make cmake ninja perl tmux curl ca-certificates pkg-config
command -v node >/dev/null 2>&1 || pkg install -y nodejs-lts
command -v cargo >/dev/null 2>&1 || pkg install -y rust
hash -r
for tool in git python clang make cmake ninja perl tmux curl npm node cargo; do
  command -v "$tool" >/dev/null || die "缺少必需工具：$tool"
done
node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if (( node_major < 20 )); then
  pkg install -y nodejs-lts
  hash -r
  node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
fi
(( node_major >= 20 )) || die "Node.js 需要 >=20，当前为 $(node -v)"
mkdir -p "$HOME/.gyp"
if [[ ! -e "$HOME/.gyp/include.gypi" ]]; then
  printf '%s\n' "{'variables': {'android_ndk_path': ''}}" > "$HOME/.gyp/include.gypi"
elif grep -q "android_ndk_path" "$HOME/.gyp/include.gypi"; then
  info '保留已有 ~/.gyp/include.gypi（已包含 android_ndk_path）。'
else
  info '保留已有 ~/.gyp/include.gypi；若 node-gyp 报 Android NDK 变量错误，请手工加入 android_ndk_path。'
fi

mkdir -p "$(dirname "$APP_DIR")" "$CONFIG_DIR" "$BIN_DIR"
if [[ -e "$APP_DIR" ]]; then
  git -C "$APP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "目标路径不是 Git 仓库：$APP_DIR（不会覆盖它）"
  info "使用已有仓库：$APP_DIR"
  [[ -z "$(git -C "$APP_DIR" status --porcelain --untracked-files=all)" ]] || { git -C "$APP_DIR" status --short; die '工作树（含未跟踪文件）不干净，拒绝覆盖本地源码。'; }
  existing_url="$(git -C "$APP_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$existing_url" ]]; then
    git -C "$APP_DIR" remote add origin "$REPO_URL"
    existing_url="$REPO_URL"
  elif [[ "$existing_url" != "$REPO_URL" ]]; then
    die "origin URL 是 $existing_url，不是请求的 $REPO_URL；请设置正确的 CODEX_PROXY_REPO_URL 或人工确认后修改。"
  fi
  info "origin: $existing_url；部署分支：$BRANCH"
  git -C "$APP_DIR" fetch origin "$BRANCH"
  if git -C "$APP_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$APP_DIR" checkout "$BRANCH"
    local_head="$(git -C "$APP_DIR" rev-parse "$BRANCH")"
    remote_head="$(git -C "$APP_DIR" rev-parse "origin/$BRANCH")"
    if [[ "$local_head" != "$remote_head" ]]; then
      git -C "$APP_DIR" merge-base --is-ancestor "$local_head" "$remote_head" || \
        die "本地 $BRANCH 与 origin/$BRANCH 已分叉；安装器不会覆盖本地提交。部署副本请改用 codex-proxy update，开发副本请人工 rebase。"
      git -C "$APP_DIR" merge --ff-only "origin/$BRANCH"
    fi
  else
    git -C "$APP_DIR" checkout -b "$BRANCH" --track "origin/$BRANCH"
  fi
else
  info "克隆 $REPO_URL ($BRANCH)"
  git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

cat > "$CONFIG_DIR/service.env" <<EOF
APP_DIR=$(printf '%q' "$APP_DIR")
BRANCH=$(printf '%q' "$BRANCH")
PORT=$(printf '%q' "$PORT")
SESSION=$(printf '%q' "$SESSION")
CONFIG_DIR=$(printf '%q' "$CONFIG_DIR")
EOF
chmod 600 "$CONFIG_DIR/service.env"
for name in build.sh run.sh control.sh; do chmod +x "$APP_DIR/scripts/termux/$name"; done
ln -sfn "$APP_DIR/scripts/termux/control.sh" "$BIN_DIR/codex-proxy"
mkdir -p "$APP_DIR/data"
if [[ ! -f "$APP_DIR/data/local.yaml" ]]; then
  api_key="$(python -c 'import secrets; print("cp_" + secrets.token_urlsafe(32))')"
  cat > "$APP_DIR/data/local.yaml" <<EOF
server:
  host: 127.0.0.1
  port: $PORT
  proxy_api_key: $api_key
client:
  platform: linux
  arch: arm64
update:
  auto_update: false
EOF
  chmod 600 "$APP_DIR/data/local.yaml"
  info '已创建 data/local.yaml；已有配置不会被覆盖。'
else
  info '保留已有 data/local.yaml。'
fi
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  touch "$rc"
  grep -qF "export PATH=\"\$HOME/.local/bin:\$PATH\"" "$rc" || printf "\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\n" >> "$rc"
done
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/start-codex-proxy" <<'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
export PATH="$HOME/.local/bin:/data/data/com.termux/files/usr/bin:$PATH"
termux-wake-lock 2>/dev/null || true
sleep 8
BOOT
printf 'CODEX_PROXY_CONFIG_DIR=%q %q start >> %q 2>&1\n' \
  "$CONFIG_DIR" "$BIN_DIR/codex-proxy" "$CONFIG_DIR/boot.log" \
  >> "$HOME/.termux/boot/start-codex-proxy"
chmod +x "$HOME/.termux/boot/start-codex-proxy"
if [[ "${CODEX_PROXY_SKIP_BUILD:-0}" != 1 ]]; then "$APP_DIR/scripts/termux/build.sh"; else info 'CODEX_PROXY_SKIP_BUILD=1，跳过构建。'; fi
if [[ "${CODEX_PROXY_SKIP_START:-0}" != 1 ]]; then "$APP_DIR/scripts/termux/control.sh" start; else info 'CODEX_PROXY_SKIP_START=1，跳过启动。'; fi
info "安装完成。控制命令：$BIN_DIR/codex-proxy"
