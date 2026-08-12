#!/usr/bin/env bash
set -eo pipefail

cd "$(dirname "$0")/koreader"

# 确保插件软链接存在
ln -sfn "$(pwd)/../book.koplugin" "$(pwd)/plugins/book.koplugin"

# 注入 GNU 工具链（kodev 要求 bash >= 4 + GNU make/findutils 等）
HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="${HOMEBREW_PREFIX}/opt/bash/bin:${HOMEBREW_PREFIX}/opt/findutils/libexec/gnubin:${HOMEBREW_PREFIX}/opt/gnu-getopt/bin:${HOMEBREW_PREFIX}/opt/make/libexec/gnubin:${HOMEBREW_PREFIX}/opt/util-linux/bin:${PATH}"

./kodev run "$@"
