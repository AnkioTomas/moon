--[[--
阅读（Legado）源设置：Web 服务地址。

在阅读 App「我的 → Web 服务」打开服务，把页面上的地址（如 http://192.168.1.8:1122）填进来；
保存时先拉一次书架校验，通过才落盘并重载源。

@module koplugin.book.source.legado.setting
--]]

require("l10n").apply()
local _ = require("gettext")
local T = require("ffi/util").template

local SOURCE_ID = "legado"
local Setting = {}

---@return string, boolean
function Setting.rowStatus()
    local on = require("source.legado.client").base() ~= nil
    return on and _("已配置") or _("未配置"), on
end

---@param address string
local function save(address)
    local Toast = require("ui.themes.widgets.toast")
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    local previous = cfg.server_address
    cfg.server_address = address
    local Client = require("source.legado.client")
    local waiting = require("ui.themes.widgets.progress_dialog"):new{
        title = _("阅读"), text = _("正在连接阅读服务…"), dismissable = false,
    }
    waiting:show()
    -- 先落盘才能让 Client 读到新地址；校验失败再还原。
    settings.saveSource(SOURCE_ID, cfg)
    Client.shelfAsync(function(rows, err)
        waiting:close()
        if not rows then
            cfg.server_address = previous
            settings.saveSource(SOURCE_ID, cfg)
            Toast:new{ text = err or _("连接失败"), timeout = 3 }:show()
            return
        end
        require("source.registry").reload()
        Toast:new{ text = T(_("已连接，书架共 %1 本"), #rows), timeout = 2 }:show()
    end)
end

local function edit()
    require("ui.themes.widgets.input"):new{
        title = _("阅读服务地址"),
        fields = { { text = require("source.legado.client").base() or "", hint = "http://192.168.1.8:1122" } },
        ok_text = _("保存"),
        callback = function(value)
            local address = require("utils.text").stripWhitespace(value)
            if address == "" then
                local cfg = require("utils.settings").getSource(SOURCE_ID)
                cfg.server_address = nil
                require("utils.settings").saveSource(SOURCE_ID, cfg)
                require("source.registry").reload()
                return
            end
            require("ui/network/manager"):runWhenOnline(function() save(address) end)
        end,
    }:show()
end

---@return table[]
function Setting.rows()
    return {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return require("ui.themes.widgets.row").widget({
                width = iw, chevron = true, kind = "nav", icon = "dns", title = _("阅读服务地址"),
                status = require("source.legado.client").base() or status, status_on = status_on,
                callback = edit,
            })
        end,
    }
end

return Setting
