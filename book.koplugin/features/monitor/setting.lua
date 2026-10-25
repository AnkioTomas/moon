--[[--
运行状态设置入口：根页系统组「运行状态」，列出占用内存 / CPU 最高的进程，10 秒刷新。

没有配置项；页面在 `page.lua`。读不到 /proc 的平台（模拟器在 macOS 上）页内只显示不支持。

@module koplugin.book.features.monitor.setting
--]]

local _ = require("gettext")

local Setting = {}

local REFRESH_SECONDS = 10

---@param desktop BookDesktop
---@return BookSettingEntry[]
function Setting.entries(desktop)
    return {
        {
            id = "main",
            group = "system",
            order = 60,
            icon = "monitoring",
            title = _("运行状态"),
            subtitle = _("进程的内存与 CPU 占用"),
            page = {
                title = _("运行状态"),
                refresh_seconds = REFRESH_SECONDS,
                right_icon = "swap_vert",
                right_callback = function() require("features.monitor.page").toggleSort(desktop) end,
                sections = function() return require("features.monitor.page").sections(desktop) end,
            },
        },
    }
end

return Setting
