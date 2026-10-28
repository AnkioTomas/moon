--[[--
阅读（Legado）源设置：Web 服务地址。

在阅读 App「我的 → Web 服务」打开服务，把页面上的地址（如 http://192.168.1.8:1122）填进来；
reader3 服务器版地址带 /reader3 后缀（如 http://host:8080/reader3）、轻阅读带 /api/5 后缀，
并填账号密码（后端类型按后缀判断）；
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
---@param user string
---@param password string
local function save(address, user, password)
    local Toast = require("ui.themes.widgets.toast")
    local settings = require("utils.settings")
    local cfg = settings.getSource(SOURCE_ID)
    local previous = { cfg.server_address, cfg.username, cfg.password }
    cfg.server_address, cfg.username, cfg.password = address, user ~= "" and user or nil, password ~= "" and password or nil
    local Client = require("source.legado.client")
    local waiting = require("ui.themes.widgets.progress_dialog"):new{
        title = _("开源阅读"), text = _("正在连接阅读服务…"), dismissable = false,
    }
    waiting:show()
    -- 先落盘才能让 Client 读到新配置；校验失败再还原。
    settings.saveSource(SOURCE_ID, cfg)
    Client.shelfAsync(function(rows, err)
        waiting:close()
        if not rows then
            cfg.server_address, cfg.username, cfg.password = previous[1], previous[2], previous[3]
            settings.saveSource(SOURCE_ID, cfg)
            Toast:new{ text = err or _("连接失败"), timeout = 3 }:show()
            return
        end
        require("source.registry").reload()
        Toast:new{ text = T(_("已连接，书架共 %1 本"), #rows), timeout = 2 }:show()
    end)
end

local function edit()
    local cfg = require("utils.settings").getSource(SOURCE_ID)
    require("ui.themes.widgets.input"):new{
        title = _("阅读服务"),
        fields = {
            { text = require("source.legado.client").base() or "", hint = "http://192.168.1.8:1122" },
            { text = cfg.username or "", hint = _("账号（reader3 服务器版才需要）") },
            { text = cfg.password or "", hint = _("密码"), text_type = "password" },
        },
        ok_text = _("保存"),
        callback = function(value, user, password)
            local Text = require("utils.text")
            local address = Text.stripWhitespace(value)
            if address == "" then
                cfg.server_address, cfg.username, cfg.password = nil, nil, nil
                require("utils.settings").saveSource(SOURCE_ID, cfg)
                require("source.registry").reload()
                return
            end
            require("ui/network/manager"):runWhenConnected(function()
                save(address, Text.stripWhitespace(user), password)
            end)
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
