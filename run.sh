#!/usr/bin/env bash
set -eo pipefail

cd "$(dirname "$0")/koreader"

# 确保插件软链接存在
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

./kodev run "$@"
