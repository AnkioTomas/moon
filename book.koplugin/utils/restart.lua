--[[--
重启 KOReader：走 KOReader 自己的重启动作（广播 Restart → DeviceListener → exitOrRestart）。
阅读器 / 文件管理器先 onClose（sidecar、阅读会话、各 onExit 落盘）再退出；禁止直接 restartKOReader。

no-framework 启动复用官方 koreader.sh --framework_stop，不能走 Restart（退出码 85 会按原参数重来）。

@module koplugin.book.utils.restart
--]]

local UIManager = require("ui/uimanager")

local Restart = {}

function Restart.now()
    UIManager:broadcastEvent(require("ui/event"):new("Restart"))
end

--- 当前是否值得切到 no-framework（Kindle 且框架仍在跑）。
function Restart.canNoFramework()
    return require("utils.mem").canOfferNoFramework()
end

--- 先干净退出（走 Exit，不要 quit(85)，否则父进程 koreader.sh 会按原参数重启、框架还在），
--- 再按官方入口拉起：koreader.sh --framework_stop。
--- 后台脚本等当前 koreader.sh 退干净，避免和本轮退出抢实例。
function Restart.noFramework()
    local logger = require("utils.log")
    local lfs = require("libs/libkoreader-lfs")
    local dir = lfs.currentdir()
    if not dir or lfs.attributes(dir .. "/koreader.sh", "mode") ~= "file" then
        dir = require("datastorage"):getDataDir()
    end
    logger.warn("book.mem restart no-framework", "dir=" .. tostring(dir))
    logger.flushSync()
    local quoted = "'" .. tostring(dir):gsub("'", "'\\''") .. "'"
    local script = "/tmp/moon-nofw.sh"
    local f, err = io.open(script, "w")
    if not f then
        logger.warn("book.mem no-framework script failed", err)
        logger.flushSync()
        return
    end
    f:write([[#!/bin/sh
reader=$(pgrep -o reader.lua) || exit 1
parent=$(awk '{print $4}' /proc/$reader/stat)
i=0
while [ -d /proc/$parent ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
cd ]] .. quoted .. [[ || exit 1
exec ./koreader.sh --framework_stop
]])
    f:close()
    os.execute("chmod 755 '" .. script .. "' && setsid nohup '" .. script .. "' >/tmp/moon-nofw.log 2>&1 </dev/null &")
    -- 走 Exit 而非 Restart：Exit 会 onClose 落盘后以非 85 退出，父脚本结束；Restart 是 quit(85)，会原样重来。
    UIManager:broadcastEvent(require("ui/event"):new("Exit"))
end

return Restart
