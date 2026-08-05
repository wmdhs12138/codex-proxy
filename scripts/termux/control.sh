#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="${CODEX_PROXY_CONFIG_DIR:-$HOME/.config/codex-proxy-termux}"
ENV_FILE="$CONFIG_DIR/service.env"
[[ -f "$ENV_FILE" ]] || { echo "未找到 $ENV_FILE，请先运行 install.sh。" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${APP_DIR:=$ROOT_DIR}"; : "${PORT:=8080}"; : "${SESSION:=codex-proxy}"
LOG_FILE="$APP_DIR/data/termux-service.log"; RUNNER="$APP_DIR/scripts/termux/run.sh"; BUILDER="$APP_DIR/scripts/termux/build.sh"
URL="http://127.0.0.1:$PORT"
HEALTH_TIMEOUT="${CODEX_PROXY_HEALTH_TIMEOUT:-15}"
[[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || { echo 'CODEX_PROXY_HEALTH_TIMEOUT 必须是非负整数。' >&2; exit 1; }
running() { tmux has-session -t "$SESSION" 2>/dev/null; }
http_ready() { curl -fsS --max-time 3 "$URL" >/dev/null 2>&1; }
wait_for_http() {
  local waited
  for ((waited = 0; waited <= HEALTH_TIMEOUT; waited++)); do
    http_ready && return 0
    (( waited < HEALTH_TIMEOUT )) && sleep 1
  done
  return 1
}
start_service() {
  mkdir -p "$APP_DIR/data"
  if running; then
    if http_ready; then echo "已运行且 HTTP 正常：$SESSION ($URL)"; return 0; fi
    echo "tmux 已运行，但 HTTP 未响应：$URL（请运行 codex-proxy logs）" >&2
    return 1
  fi
  command -v tmux >/dev/null || { echo '需要 tmux。' >&2; return 1; }
  tmux_command="exec $(printf '%q' "$RUNNER") >> $(printf '%q' "$LOG_FILE") 2>&1"
  tmux new-session -d -s "$SESSION" -c "$APP_DIR" "$tmux_command"
  sleep 2
  if ! running; then echo '启动失败，最近日志：' >&2; tail -n 80 "$LOG_FILE" 2>/dev/null || true; return 1; fi
  if wait_for_http; then echo "已启动且 HTTP 正常：$URL"; return 0; fi
  echo "tmux 已启动，但等待 ${HEALTH_TIMEOUT}s 后 HTTP 仍未响应：$URL（请运行 codex-proxy logs）" >&2
  return 1
}
stop_service() {
  if ! running; then echo '当前未运行。'; return 0; fi
  tmux send-keys -t "$SESSION" C-c 2>/dev/null || true; sleep 2; tmux kill-session -t "$SESSION" 2>/dev/null || true; echo '已停止。'
}
status_service() {
  running && echo "tmux：运行中（$SESSION）" || echo 'tmux：未运行'
  curl -fsS --max-time 3 "$URL" >/dev/null 2>&1 && echo "HTTP：正常（$URL）" || echo "HTTP：无响应（$URL）"
}
clean_tree() { [[ -z "$(git status --porcelain --untracked-files=all)" ]]; }
update_service() {
  cd "$APP_DIR"
  clean_tree || { git status --short; echo '工作树（含未跟踪文件）不干净，拒绝更新。' >&2; return 1; }
  local current rollback_ref old_head stale_ref
  local -a stale_refs
  current="$(git branch --show-current)"; [[ "$current" == "$BRANCH" ]] || { echo "当前分支是 $current，不是部署分支 $BRANCH。" >&2; return 1; }
  echo "先 fetch origin/$BRANCH（服务仍运行）"
  git fetch origin "$BRANCH"
  old_head="$(git rev-parse HEAD)"; rollback_ref="refs/codex-proxy/rollback/$(date +%Y%m%d-%H%M%S)-${old_head:0:12}"
  git update-ref "$rollback_ref" "$old_head"
  mapfile -t stale_refs < <(git for-each-ref --sort=-refname --format='%(refname)' refs/codex-proxy/rollback/ | tail -n +11)
  for stale_ref in "${stale_refs[@]}"; do git update-ref -d "$stale_ref"; done
  echo "旧 HEAD：$old_head；回滚引用：$rollback_ref（最多保留最近 10 个）"
  stop_service
  echo "部署 origin/$BRANCH：明确 reset --hard（不会触碰 data/）"
  git reset --hard "origin/$BRANCH"
  if "$BUILDER"; then
    start_service || { echo '新版本构建成功但启动失败；服务保持停止，请检查日志。' >&2; return 1; }
    echo "更新成功：$(git rev-parse HEAD)"
    return 0
  fi
  echo '新版本构建失败，恢复旧 HEAD 并尝试重建旧版本。' >&2
  git reset --hard "$old_head"
  if "$BUILDER" && start_service; then
    echo "已恢复旧版本 $old_head；更新失败。" >&2
  else
    echo '更新失败，旧版本恢复/重建/启动也失败；服务保持停止。' >&2
  fi
  return 1
}
show_key() { [[ -f "$APP_DIR/data/local.yaml" ]] || { echo '未找到 data/local.yaml' >&2; return 1; }; awk '/^[[:space:]]*proxy_api_key:[[:space:]]*/ { sub(/^[[:space:]]*proxy_api_key:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$APP_DIR/data/local.yaml"; }
case "${1:-help}" in
  start) start_service;; stop) stop_service;; restart) stop_service; start_service;; status) status_service;;
  logs) touch "$LOG_FILE"; exec tail -n 200 -f "$LOG_FILE";; attach) exec tmux attach-session -t "$SESSION";; build) exec "$BUILDER";; update) update_service;; key) show_key;; url) echo "$URL";;
  help|-h|--help) cat <<'EOF'
用法：codex-proxy {start|stop|restart|status|logs|attach|build|update|key|url|help}
start 启动 tmux 并等待 HTTP 健康检查（默认 15 秒，可用 CODEX_PROXY_HEALTH_TIMEOUT 调整）。
update 先 fetch，在干净工作树上创建回滚引用并部署 origin/分支；最多保留最近 10 个回滚引用。
update 新构建失败会尽力恢复旧 HEAD、重建并启动；失败时返回非零，且绝不修改 data/。
EOF
  ;;
  *) echo "未知命令：$1" >&2; exit 2;;
esac
