#!/usr/bin/env bash
# 离线单元测试（不启 KOReader）
# 用法：./tests/run.sh [spec 文件…]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec luajit tests/run.lua "$@"
