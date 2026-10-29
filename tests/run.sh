#!/usr/bin/env bash
# 离线单元测试（不启 KOReader），只需系统 luajit + libsqlite3。
# 用法：./tests/run.sh [spec 文件…]
# 数据目录默认仓库根 test/（沙箱，git 忽略），KO_HOME 可覆盖；细节见 tests/run.lua 头注释。
set -euo pipefail
cd "$(dirname "$0")/.."
exec luajit tests/run.lua "$@"
