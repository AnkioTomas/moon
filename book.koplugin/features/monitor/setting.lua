--[[--
运行状态：挂在「我的设备 → 本机」，点进去才是这一页。列出占用内存 / CPU 最高的进程，10 秒刷新。

没有配置项；页面在 `page.lua`。读不到 /proc 的平台（模拟器在 macOS 上）页内只显示不支持。

@module koplugin.book.features.monitor.setting
--]]

local _ = require("gettext")

local Setting = {}

local REFRESH_SECONDS = 10

require("utils.extension").add("setting.device_section", {
    id = "monitor",
    order = 20,
    icon = "monitoring",
    title = _("运行状态"),
    docs = "/manual/device/monitor",
    status = function()
        local mem = require("features.monitor.procs").memory()
        if not mem then return nil end
        local friendly = require("util").getFriendlySize
        local function kb(n) return friendly(n * 1024) end
        return require("ffi/util").template(_("%1 / %2"), kb(mem.avail), kb(mem.total))
    end,
    refresh_seconds = REFRESH_SECONDS,
    right_icon = "swap_vert",
    right_callback = function(desktop) require("features.monitor.page").toggleSort(desktop) end,
    sections = function(desktop) return require("features.monitor.page").sections(desktop) end,
})

return Setting
