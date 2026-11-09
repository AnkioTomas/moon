--[[--
阅读（Legado）源设置：Web 服务地址。

在阅读 App「我的 → Web 服务」打开服务，把页面上的地址（如 http://192.168.1.8:1122）填进来；
手机 IP 会变，也可以扫本机所在网段，认端口上的阅读服务。
reader3 服务器版地址带 /reader3 后缀（如 http://host:8080/reader3）、轻阅读带 /api/5 后缀，
并填账号密码（后端类型按后缀判断）；
保存时先拉一次书架校验，通过才落盘并重载源。

@module koplugin.book.source.legado.setting
--]]

local _ = require("l10n").get("source.legado")
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
    local previous_user = cfg.username or ""
    local next_cfg = { server_address = address, username = user ~= "" and user or nil,
        password = password ~= "" and password or nil }
    local function commit()
        cfg.server_address, cfg.username, cfg.password = next_cfg.server_address, next_cfg.username, next_cfg.password
        settings.saveSource(SOURCE_ID, cfg)
    end
    local Client = require("source.legado.client")
    local waiting = require("ui.themes.widgets.progress_dialog"):new{
        title = _("开源阅读"), text = _("正在连接阅读服务…"), dismissable = false,
    }
    waiting:show()
    Client.shelfAsync(function(rows, err)
        waiting:close()
        if not rows then
            Toast:new{ text = err or _("连接失败"), timeout = 3 }:show()
            return
        end
        -- 手机 IP 会变化，地址不是书籍身份；换账号也只准备同步，不清记录。
        if previous_user ~= user then
            if not require("source.logout").replaceLibrary(SOURCE_ID, commit) then
                Toast:new{ text = _("准备本地同步失败"), timeout = 3 }:show()
                return
            end
        else
            if cfg.server_address ~= address then require("source.logout").abort(SOURCE_ID) end
            commit()
            require("source.registry").reload()
        end
        Toast:new{ text = T(_("已连接，书架共 %1 本"), #rows), timeout = 2 }:show()
    end, next_cfg)
end

local scanning = false

local function scan()
    if scanning then return end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if scanning then return end
        scanning = true
        local waiting, handle, closed
        waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("开源阅读"),
            text = _("正在扫描局域网…"),
            dismissable = false,
            on_cancel = function()
                -- 弹窗自己先关。这里只停扫描。
                if closed then return end
                closed = true
                scanning = false
                if handle then handle.cancel() end
            end,
        }
        waiting:show()
        handle = require("source.legado.scan").find(function(found, err)
            if closed then return end
            closed = true
            scanning = false
            waiting:close()
            local Toast = require("ui.themes.widgets.toast")
            if type(found) ~= "table" or #found == 0 then
                local text = err == "no-ip" and _("没有局域网地址") or _("没有找到阅读服务")
                Toast:new{ text = text, timeout = 3 }:show()
                return
            end
            local cfg = require("utils.settings").getSource(SOURCE_ID)
            local user, password = cfg.username or "", cfg.password or ""
            if #found == 1 then
                save(found[1], user, password)
                return
            end
            local items = {}
            for _idx, address in ipairs(found) do
                items[#items + 1] = { text = address, value = address }
            end
            require("ui.themes.widgets.list"):new{
                title = _("选择阅读服务"),
                items = items,
                on_select = function(value) save(value, user, password) end,
            }:show()
        end)
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
                require("source.logout").abort(SOURCE_ID)
                cfg.server_address = nil
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
    local rows = {
        function(iw)
            local status, status_on = Setting.rowStatus()
            return require("ui.themes.widgets.row").widget({
                width = iw, chevron = true, kind = "nav", icon = "dns", title = _("阅读服务地址"),
                status = require("source.legado.client").base() or status, status_on = status_on,
                callback = edit,
            })
        end,
        function(iw)
            return require("ui.themes.widgets.row").widget({
                width = iw, chevron = true, kind = "nav", icon = "wifi_find", title = _("扫描局域网"),
                callback = scan,
            })
        end,
    }
    if require("source.legado.client").base() ~= nil then
        rows[#rows + 1] = require("source.logout").row(SOURCE_ID, _("确定退出开源阅读？"), function()
            local settings = require("utils.settings")
            local cfg = settings.getSource(SOURCE_ID)
            cfg.server_address, cfg.username, cfg.password = nil, nil, nil
            settings.saveSource(SOURCE_ID, cfg)
        end)
    end
    return rows
end

return Setting
