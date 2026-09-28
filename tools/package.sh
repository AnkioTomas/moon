#!/bin/sh
# 打包 book.koplugin（Release Action 与本地通用）
# 用法：tools/package.sh [VERSION] [OUT_ZIP]
#   VERSION  注入 bookversion.lua；省略则保持 0.0.0-dev
#   OUT_ZIP  输出路径，默认仓库根 book.koplugin.zip
# 剔除：types/（仅 LuaLS 用）、*.md、.DS_Store、*~；Lua 文档注解经 tools/strip_lua.lua 剥离。
# 只改临时目录里的副本，源码树不动。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
OUT="${2:-$ROOT/book.koplugin.zip}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

rsync -a \
    --exclude '/types/' \
    --exclude '*.md' \
    --exclude '.DS_Store' \
    --exclude '*~' \
    "$ROOT/book.koplugin/" "$STAGE/book.koplugin/"

find "$STAGE/book.koplugin" -name '*.lua' -exec "${LUAJIT:-luajit}" "$ROOT/tools/strip_lua.lua" {} +

if [ -n "$VERSION" ]; then
    printf 'return "%s"\n' "$VERSION" > "$STAGE/book.koplugin/bookversion.lua"
fi

rm -f "$OUT"
(cd "$STAGE" && zip -qrX "$OUT" book.koplugin)
echo "Packaged $OUT${VERSION:+ (version $VERSION)}"
