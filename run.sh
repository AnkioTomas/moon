#!/usr/bin/env bash
set -eo pipefail

cd "$(dirname "$0")/koreader"

# 确保插件软链接存在；真实目录会让 ln 把链接建进目录里，模拟器继续加载旧拷贝
if [ -d plugins/book.koplugin ] && [ ! -L plugins/book.koplugin ]; then
    stale="$(mktemp -d /tmp/book.koplugin.stale.XXXXXX)"
    mv plugins/book.koplugin "$stale/"
    echo "run.sh: 旧插件拷贝已移到 $stale，改为软链到仓库" >&2
fi
ln -sfn "$(pwd)/../book.koplugin" "$(pwd)/plugins/book.koplugin"

# 注入 GNU 工具链（kodev 要求 bash >= 4 + GNU make/findutils 等）
HOMEBREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="${HOMEBREW_PREFIX}/opt/bash/bin:${HOMEBREW_PREFIX}/opt/findutils/libexec/gnubin:${HOMEBREW_PREFIX}/opt/gnu-getopt/bin:${HOMEBREW_PREFIX}/opt/make/libexec/gnubin:${HOMEBREW_PREFIX}/opt/util-linux/bin:${PATH}"

# Homebrew CMake 4.x 拒绝 cmake_minimum_required < 3.5；第三方源（如未打上补丁的
# lunasvg）仍会触发。官方逃生阀：按 ≥3.5 政策解释旧工程。
export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

# 第三方 git checkout / 半截手工打补丁 会弄脏 source：overlay 丢了、PATCH_FILES
# 只打了一部分，但 prepare stamp 仍在 → 后续 cmake regenerate / 链接缺符号。
# 这里统一检出后强制重跑 prepare（保留 download）。
repair_stale_thirdparty() {
    local pkg src root stamp overlay_cmake patch needs reason
    shopt -s nullglob

    for pkg_cmake in base/thirdparty/*/CMakeLists.txt; do
        pkg="$(basename "$(dirname "$pkg_cmake")")"
        # 只管带 overlay 或 .patch 的包
        overlay_cmake="base/thirdparty/$pkg/overlay/CMakeLists.txt"
        patches=(base/thirdparty/"$pkg"/*.patch)
        if [ ! -f "$overlay_cmake" ] && [ ${#patches[@]} -eq 0 ]; then
            continue
        fi

        for src in base/build/*/thirdparty/"$pkg"/source; do
            [ -d "$src" ] || continue
            root="$(dirname "$src")"
            stamp="$root/stamp"
            needs=0
            reason=""

            if [ -f "$overlay_cmake" ]; then
                if [ ! -f "$src/CMakeLists.txt" ] \
                    || ! diff -q "$overlay_cmake" "$src/CMakeLists.txt" >/dev/null 2>&1; then
                    needs=1
                    reason="overlay"
                fi
            fi

            # 任一补丁还能 --forward 干跑成功 = 还没打上
            if [ "$needs" -eq 0 ] && [ ${#patches[@]} -gt 0 ]; then
                for patch in "${patches[@]}"; do
                    if (cd "$src" && patch -p1 --dry-run --forward --input="$patch" >/dev/null 2>&1); then
                        needs=1
                        reason="patch:$(basename "$patch")"
                        break
                    fi
                done
            fi

            if [ "$needs" -eq 1 ]; then
                echo "run.sh: repairing stale thirdparty '$pkg' ($reason)"
                rm -f "$stamp/prepare" "$stamp/configure" "$stamp/build" "$stamp/install"
                rm -rf "$root/build"
            fi
        done
    done
}
repair_stale_thirdparty

if [ "$1" != "--watch" ]; then
    exec ./kodev run "$@"
fi
shift

# --watch：插件目录有改动就重启模拟器。Lua 模块与 features 补丁不支持进程内卸载，只能整进程重启。
./kodev build
stamp="$(mktemp -t book.koplugin.watch)"
pid=
# 每次 kodev run 自成进程组，重启时整组杀：逐个枚举子进程会漏掉枚举后才拉起的 make/luajit，
# 漏掉的那个变成孤儿模拟器，两个进程共用数据目录（临时文件、sqlite 互相踩）。
set -m
stop() {
    [ -n "$pid" ] || return 0
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    pid=
}
trap 'stop; rm -f "$stamp"; exit 0' INT TERM
while :; do
    touch "$stamp"
    ./kodev run -b "$@" &
    pid=$!
    until [ -n "$(find ../book.koplugin -newer "$stamp" -print -quit)" ]; do sleep 1; done
    # 防抖：连续 5 秒没有新改动才重启，期间每次改动都重新计时。
    echo "run.sh: 插件有改动，静默 5 秒后重启" >&2
    quiet=0
    touch "$stamp"
    while [ "$quiet" -lt 5 ]; do
        sleep 1
        if [ -n "$(find ../book.koplugin -newer "$stamp" -print -quit)" ]; then
            touch "$stamp"
            quiet=0
        else
            quiet=$((quiet + 1))
        fi
    done
    echo "run.sh: 重启模拟器" >&2
    stop
done
