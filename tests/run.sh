#!/usr/bin/env bash
# 离线单元测试（不启 KOReader）
# 用法：./tests/run.sh [spec 文件…]
#
# 真配置：KO_HOME=仓库根 config/；业务读写走 moon.settings
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export KO_HOME="${KO_HOME:-$ROOT/config}"
exec luajit tests/run.lua "$@"
