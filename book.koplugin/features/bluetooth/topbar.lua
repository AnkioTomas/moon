--[[--
蓝牙的桌面顶栏项：没装 kindle-hid-passthrough 不显示；关着画 bluetooth_disabled，
开着画 bluetooth，连上一台显示名字、多台显示台数；点按打开蓝牙窗口。

@module koplugin.book.features.bluetooth.topbar
--]]

require("l10n").apply()

local _ = require("gettext")

local Topbar = {}

---@return BookTopBarItem[]
function Topbar.items()
    if not require("features.bluetooth").installed() then return {} end
    return {
        {
            id = "bluetooth",
            label = _("蓝牙"),
            icon = "bluetooth",
            bar_icon = "bluetooth",
            max_ratio = 0.25,
            watch = function(cb) return require("features.bluetooth").watch(cb) end,
            read = function() return require("features.bluetooth").topbar() end,
            tap = function() require("features.bluetooth.devices").show() end,
        },
    }
end

return Topbar
