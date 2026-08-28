#!/usr/bin/env bash
# 离线单元测试（不启 KOReader）
# 用法：./tests/run.sh [spec 文件…]
#
# 数据目录：仓库根 test/（沙箱，git 忽略），不是模拟器的 config/。
# 测试会往数据目录里写配置、sqlite、缓存文件，绝不能落到真实数据上。
# native 库（libkoreader-lfs 等）无法凭空造，软链回 config/libs 只读使用。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SANDBOX="${KO_HOME:-$ROOT/test}"
mkdir -p "$SANDBOX/.moon/settings" "$SANDBOX/.moon/cache" "$SANDBOX/settings"

# native 库来自模拟器构建产物；没有 config/ 时相关 spec 会自行跳过
if [ ! -e "$SANDBOX/libs" ] && [ -d "$ROOT/config/libs" ]; then
    ln -s "$ROOT/config/libs" "$SANDBOX/libs"
fi

# 最小可用配置：Settings 读的是 LuaSettings 格式（可 dofile 的 return 表）
if [ ! -f "$SANDBOX/.moon/settings/common.lua" ]; then
    printf -- '-- %s\nreturn {}\n' \
        "$SANDBOX/.moon/settings/common.lua" > "$SANDBOX/.moon/settings/common.lua"
fi

export KO_HOME="$SANDBOX"
exec luajit tests/run.lua "$@"
