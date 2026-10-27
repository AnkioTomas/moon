#!/usr/bin/env bash
# 临时目录铺几千本假书，跑本地扫盘压测（不启 KOReader）。
# 用法：
#   ./tools/bench_local_scan.sh              # 默认 3000 本
#   COUNT=5000 ./tools/bench_local_scan.sh
#   COUNT=3000 ENRICH_MS=50 ./tools/bench_local_scan.sh   # 每本补齐多睡 50ms 模拟墨水屏
#   SKIP_CREATE=1 ./tools/bench_local_scan.sh             # 复用已有 /tmp/moon-bench/books
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export COUNT="${COUNT:-3000}"
export BOOKS="${BOOKS:-/tmp/moon-bench/books}"
export KO_HOME="${KO_HOME:-/tmp/moon-bench/data}"
export ENRICH_MS="${ENRICH_MS:-0}"

mkdir -p "$KO_HOME/.moon/settings" "$KO_HOME/.moon/cache" "$KO_HOME/settings"
if [[ ! -f "$KO_HOME/.moon/settings/common.lua" ]]; then
    printf -- '-- %s\nreturn {}\n' "$KO_HOME/.moon/settings/common.lua" > "$KO_HOME/.moon/settings/common.lua"
fi

# 软链模拟器 libs，给 libkoreader-lfs / sqlite
EMU="$(ls -d "$ROOT"/koreader/koreader-emulator-*/koreader 2>/dev/null | sort -r | head -1 || true)"
if [[ -n "$EMU" && ! -e "$KO_HOME/libs" ]]; then
    ln -s "$EMU/libs" "$KO_HOME/libs"
fi

echo "COUNT=$COUNT BOOKS=$BOOKS KO_HOME=$KO_HOME ENRICH_MS=$ENRICH_MS"
exec luajit "$ROOT/tools/bench_local_scan.lua" "$@"
