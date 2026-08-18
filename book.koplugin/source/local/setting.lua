--[[--
本地源设置 UI（书库目录由本模块自绘）。
读写：utils.settings.getSource / saveSource("local")

@module koplugin.book.source.local.setting
--]]

local _ = require("gettext")

local SOURCE_ID = "local"

local Setting = {}

--- 设置行状态文案与高亮开关。
---@return string status, boolean status_on
function Setting.rowStatus()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    local path = cfg.path or ""
    if path ~= "" then
        return path, true
    end
    return _("未配置"), false
end

--- 目录选择列表：逐层浏览，右上确认当前目录。
---@param plugin table|nil
function Setting.open(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local Popup = require("ui.components.popup")
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    local start_path = cfg.path
    if type(start_path) ~= "string" or start_path == "" then
        local home = G_reader_settings:readSetting("home_dir")
        start_path = type(home) == "string" and home:match("^(.*)/[^/]+/?$") or nil
        if not start_path or start_path == "" then
            local ffiUtil = require("ffi/util")
            local data = require("datastorage"):getFullDataDir()
            start_path = ffiUtil.dirname(ffiUtil.realpath(data) or data)
        end
    end
    Popup.directory{
        title = _("选择书库目录"),
        path = start_path,
        on_select = function(path)
            cfg.path = path
            MoonSettings.saveSource(SOURCE_ID, cfg)
            require("source.registry").invalidate()
            UIManager:show(InfoMessage:new{ text = _("已保存"), timeout = 2 })
            if plugin and plugin.onSourceChanged then
                plugin:onSourceChanged()
            end
        end,
    }
end

return Setting
