#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
export NODE_ENV=production
export CODEX_PLATFORM=linux
export CODEX_ARCH=arm64
export SSL_CERT_FILE="${SSL_CERT_FILE:-${PREFIX:-/data/data/com.termux/files/usr}/etc/tls/cert.pem}"
if [[ "${CODEX_PROXY_KEEP_PROXY:-0}" != 1 ]]; then
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
fi
exec node dist/index.js
