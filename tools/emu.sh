#!/bin/bash
# 向模拟器驱动（tools/emu_driver.lua）投递一段 Lua，打印返回值。
#   tools/emu.sh '<lua>'            执行并返回结果（首行 OK / ERR）
#   tools/emu.sh --shot <name>      全屏重绘后截图到 /tmp/moon-shots/<name>.png
set -e
run() {
    rm -f /tmp/ko_out.txt
    printf '%s' "$1" > /tmp/ko_cmd.lua.tmp && mv /tmp/ko_cmd.lua.tmp /tmp/ko_cmd.lua
    for _i in $(seq 1 100); do
        [ -f /tmp/ko_out.txt ] && { cat /tmp/ko_out.txt; echo; return 0; }
        sleep 0.2
    done
    echo "TIMEOUT（驱动没装或模拟器没在跑）"; return 1
}
if [ "$1" = "--shot" ]; then
    # 墨水屏模拟器只刷脏区：先整屏标脏重绘，等一拍再截，否则会截到残影。
    run "local U=require('ui/uimanager') U:setDirty('all','full') U:forceRePaint() return 1" >/dev/null
    sleep 1.5
    run "require('ui/uimanager'):forceRePaint() return D.shot('$2')"
else
    run "$1"
fi
