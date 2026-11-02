--[[--
重启 KOReader：走 KOReader 自己的重启动作（广播 Restart → DeviceListener → exitOrRestart）。
阅读器 / 文件管理器先 onClose（sidecar、阅读会话、各 onExit 落盘）再退出；禁止直接 restartKOReader。

@module koplugin.book.utils.restart
--]]

local UIManager = require("ui/uimanager")

local Restart = {}

function Restart.now()
    UIManager:broadcastEvent(require("ui/event"):new("Restart"))
end

return Restart
