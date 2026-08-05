#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
export npm_config_python="${npm_config_python:-${PREFIX:-/data/data/com.termux/files/usr}/bin/python}"
export CARGO_TERM_COLOR="${CARGO_TERM_COLOR:-always}"
export CMAKE_GENERATOR="${CMAKE_GENERATOR:-Ninja}"

command -v npm >/dev/null || { echo '需要 npm。' >&2; exit 1; }
command -v cargo >/dev/null || { echo '需要 cargo。' >&2; exit 1; }

echo '[1/4] npm ci（根工作区关闭）'
npm ci --workspaces=false
echo '[2/4] npm ci（web）'
npm --prefix web ci --workspaces=false
echo '[3/4] cargo release 构建 Android ARM64 TLS 模块'
(
  cd native
  cargo build --release
  test -s target/release/libcodex_tls.so
  cp -f target/release/libcodex_tls.so codex-tls.android-arm64.node
)
node - <<'NODE'
const m = require('./native/index.js')
const required = ['httpGet', 'httpPost', 'httpPostStream']
for (const key of required) if (typeof m[key] !== 'function') throw new Error(`缺少 NAPI 导出：${key}`)
console.log('NAPI exports:', Object.keys(m).join(', '))
NODE
echo '[4/4] npm run build'
npm run build
echo '构建完成。'
