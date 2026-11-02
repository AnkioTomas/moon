--[[--
Kindle 书库源设置：kindle.koplugin（开书转换依赖）的安装状态与在线安装 / 更新。
书源本身没有配置项；装没装插件都显示本页，装好后重启 KOReader 生效。

@module source.kindle.setting
--]]

local Update = require("source.kindle.plugin_update")
local _ = require("gettext")

local Setting = {}

--- 账号页该行右侧的状态：已装显示版本，没装提示。
---@return string status, boolean on
function Setting.rowStatus()
    local version = Update.target.installed()
    if version then return "v" .. version, true end
    return _("未安装"), false
end

---@param plugin table|nil
---@return fun(iw: number): table
local function pluginRow(plugin)
    return function(iw)
        local status, on = Setting.rowStatus()
        return require("ui.themes.widgets.row").widget({
            width = iw, kind = "nav", icon = "system_update", title = "kindle.koplugin",
            subtitle = on and _("Kindle 书库依赖的插件，点按检查更新")
                or _("Kindle 书库依赖的插件，点按安装"),
            status = status, status_on = on, chevron = true,
            callback = function() Update:manualCheck(plugin) end,
        })
    end
end

---@param plugin table|nil
---@return BookThemeSection[]
function Setting.sections(plugin)
    return { { title = _("Kindle 书库"), rows = { pluginRow(plugin) } } }
end

---@param plugin table|nil
---@return table[]
function Setting.rows(plugin)
    return Setting.sections(plugin)[1].rows
end

return Setting
