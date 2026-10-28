#!/usr/bin/env bash
# 本地测试用 WebDAV 服务（wsgidav，经 uv 临时拉起，不装进系统）
# 用法：./tools/webdav.sh
# 环境变量：DAV_PORT（默认 8088）、DAV_USER / DAV_PASS（默认 moon / moon）、
#          DAV_DIR（默认仓库根 webdav/，git 忽略，可随时 rm -rf）
# 只开 Basic 认证：插件 source/local/dav.lua 只会 Basic。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PORT="${DAV_PORT:-8088}"
USER_NAME="${DAV_USER:-moon}"
PASS="${DAV_PASS:-moon}"
DIR="${DAV_DIR:-$ROOT/webdav}"
mkdir -p "$DIR"

CONF="$(mktemp -t moon-webdav).yaml"
trap 'rm -f "$CONF"' EXIT
cat > "$CONF" <<EOF
host: 0.0.0.0
port: $PORT
provider_mapping:
  "/": "$DIR"
http_authenticator:
  accept_basic: true
  accept_digest: false
  default_to_digest: false
simple_dc:
  user_mapping:
    "*":
      "$USER_NAME":
        password: "$PASS"
verbose: 3
EOF

IP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo "WebDAV 目录: $DIR"
echo "模拟器地址: http://127.0.0.1:$PORT/"
[ -n "$IP" ] && echo "设备地址:   http://$IP:$PORT/"
echo "用户名/密码: $USER_NAME / $PASS"

exec uv tool run --from wsgidav --with cheroot wsgidav --config "$CONF"
