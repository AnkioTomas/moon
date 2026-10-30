#!/bin/sh
# 打包 KOReader 插件目录（Release Action 与本地通用）
# 用法：tools/package.sh [VERSION] [OUT_ZIP] [PLUGIN_DIR]
#   VERSION     注入 bookversion.lua；省略或为空则不注入（月读保持 0.0.0-dev，拓展没有版本文件）
#   OUT_ZIP     输出路径，默认仓库根 <插件目录名>.zip
#   PLUGIN_DIR  插件目录，默认 book.koplugin
# 附带 manifest.txt（模块清单）。剔除：types/（仅 LuaLS 用）、demo/（主题组件演示）、features/demo/（feature 模板）、*.md、.DS_Store、*~；Lua 文档注解经 tools/strip_lua.lua 剥离。
# 只改临时目录里的副本，源码树不动。
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
SRC="${3:-$ROOT/book.koplugin}"
case "$SRC" in /*) ;; *) SRC="$PWD/$SRC" ;; esac
SRC="${SRC%/}"
NAME="$(basename "$SRC")"
OUT="${2:-$ROOT/$NAME.zip}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

rsync -a \
    --exclude '/types/' \
    --exclude '/demo/' \
    --exclude '/features/demo/' \
    --exclude '*.md' \
    --exclude '.DS_Store' \
    --exclude '*~' \
    "$SRC/" "$STAGE/$NAME/"

find "$STAGE/$NAME" -name '*.lua' -exec "${LUAJIT:-luajit}" "$ROOT/tools/strip_lua.lua" {} +

if [ -n "$VERSION" ]; then
    printf 'return "%s"\n' "$VERSION" > "$STAGE/$NAME/bookversion.lua"
fi

# 安装完整性清单：每行一个模块名（与 utils/modules.lua 的索引键同写法），启动时 install_check.lua 对照。
[ "$NAME" = book.koplugin ] && (cd "$STAGE/$NAME" && find . -name '*.lua' | sed 's|^\./||; s|\.lua$||; s|/init$||' | grep -vx -e main -e _meta | sort -u > manifest.txt)

rm -f "$OUT"
(cd "$STAGE" && zip -qrX "$OUT" "$NAME")
echo "Packaged $OUT${VERSION:+ (version $VERSION)}"
