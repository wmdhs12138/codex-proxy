#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
BRANCH="${CODEX_PROXY_BRANCH:-termux-aarch64}"
usage() { cat <<EOF
用法：$(basename "$0") [--push]
在 $BRANCH 上 rebase upstream/master，执行 shell 与真实 Termux 构建验证；默认不 push。
--push  rebase 和验证成功后，以 force-with-lease 推送 origin/$BRANCH
EOF
}
PUSH=0
case "${1:-}" in '') ;; --push) PUSH=1 ;; -h|--help) usage; exit 0 ;; *) echo "未知参数：$1（仅支持 --push）" >&2; usage >&2; exit 2 ;; esac
[[ "$(git branch --show-current)" == "$BRANCH" ]] || { echo "必须在 $BRANCH 分支运行。" >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || { git status --short; echo '工作树（含未跟踪文件）不干净。' >&2; exit 1; }
origin_url="$(git remote get-url origin 2>/dev/null)" || { echo '缺少 origin（个人 fork）。' >&2; exit 1; }
upstream_url="$(git remote get-url upstream 2>/dev/null)" || { echo '缺少 upstream（原作者仓库）。' >&2; exit 1; }
[[ "$origin_url" != "$upstream_url" ]] || { echo 'origin 与 upstream 不能指向同一仓库。' >&2; exit 1; }
echo "origin: $origin_url"; echo "upstream: $upstream_url"
git fetch upstream master
git rebase upstream/master || { echo 'rebase 冲突：解决后 git add && git rebase --continue，或 git rebase --abort。' >&2; exit 1; }
for script in scripts/termux/*.sh; do bash -n "$script"; done
if command -v shellcheck >/dev/null 2>&1; then shellcheck -x scripts/termux/*.sh; else echo '未找到 shellcheck，跳过 shellcheck。' >&2; fi
command -v npm >/dev/null 2>&1 || { echo '未找到 npm，无法执行构建验证。' >&2; exit 1; }
npm run typecheck:scripts
scripts/termux/build.sh
if (( PUSH )); then git push --force-with-lease origin "$BRANCH"; else echo '验证完成；默认不 push。需要发布时显式运行：sync-upstream.sh --push'; fi
