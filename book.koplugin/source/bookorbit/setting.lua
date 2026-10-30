--[[--
BookOrbit 源设置：服务器地址、KOReader 同步账号、书库选择、测试连接；
装过 BookOrbit 官方插件时可一键导入它的账号。
配置经月读 utils.settings.getSource / saveSource("bookorbit") 落盘；密码只存 MD5（userkey）。

@module source.bookorbit.setting
--]]

local Client = require("source.bookorbit.client")
local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local ID = "bookorbit"

local Setting = {}

---@return table
local function config()
    return require("utils.settings").getSource(ID)
end

--- 落盘并重建源实例，让新地址 / 账号 / 书库立即生效，设置页随之刷新。
---@param cfg table
local function save(cfg)
    require("utils.settings").saveSource(ID, cfg)
    require("source.registry").reload()
end

---@param text string
local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

--- 密码 → x-auth-key（MD5，同 kosync）；空串表示清掉。
---@param value string|nil
---@return string
local function userkey(value)
    value = Text.trim(value)
    return value == "" and "" or require("ffi/sha2").md5(value) --[[@as string]]
end

--- 官方插件存在 G_reader_settings["bookorbit"] 里的账号（它的 server_url 带 /api/v1）。
---@return table|nil
local function officialAccount()
    local reader = rawget(_G, "G_reader_settings")
    local account = reader and reader:readSetting("bookorbit")
    if type(account) ~= "table" then return nil end
    local client = Client.new(account)
    return client:configured() and client or nil
end

--- 未配置 / 断网当场提示；否则带忙碌提示调 fn(client, done)，fn 结束时必须调 done()。
---@param fn fun(client: BookOrbitClient, done: fun())
local function withServer(fn)
    local client = Client.new(config())
    if not client:configured() then
        toast(_("请先填写服务器地址、用户名和密码"))
        return
    end
    if not require("ui/network/manager"):isConnected() then
        toast(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    local busy = require("ui.themes.widgets.toast"):new{ text = _("正在连接 BookOrbit…"), dismissable = false }
    busy:show()
    fn(client, function() busy:close() end)
end

---@param key string
---@param title string
---@param hint string
---@param password boolean
---@param normalize fun(value: string|nil): string
---@param icon string
---@return fun(iw: number): table
local function field(key, title, hint, password, normalize, icon)
    return function(iw)
        local value = config()[key] or ""
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = icon, title = title,
            status = value ~= "" and (password and "******" or value) or _("未设置"),
            status_on = value ~= "",
            callback = function()
                local cfg = config()
                require("ui.themes.widgets.input"):new{
                    title = title,
                    -- 密码只存摘要，回填不了原文。
                    fields = { { text = password and "" or (cfg[key] or ""), hint = hint,
                        text_type = password and "password" or nil } },
                    ok_text = _("保存"),
                    callback = function(input)
                        cfg[key] = normalize(input)
                        save(cfg)
                    end,
                }:show()
            end,
        })
    end
end

--- 多选书库：只同步选中的库；一个都不选 = 全部可访问的书库。
local function pickLibraries()
    withServer(function(client, done)
        client:json("GET", "/koreader/plugin/catalog/sections/libraries", nil, nil, function(data, err)
            done()
            if not data then
                toast(err)
                return
            end
            local cfg = config()
            local chosen = cfg.libraries or {}
            local items = {}
            for _idx, lib in ipairs(data.items or {}) do
                local id = tostring(lib.id)
                items[#items + 1] = { text = lib.title or id, value = id, checked = chosen[id] == true }
            end
            require("ui.themes.widgets.list"):new{
                title = _("选择书库（不选 = 全部）"),
                multi = true,
                items = items,
                close_callback = function()
                    local picked = {}
                    for _idx, item in ipairs(items) do
                        if item.checked then picked[item.value] = true end
                    end
                    cfg.libraries = picked
                    save(cfg)
                end,
            }:show()
        end)
    end)
end

local function testConnection()
    withServer(function(client, done)
        client:json("GET", "/koreader/users/auth", nil, nil, function(data, err)
            done()
            toast(data and data.authorized == "OK" and _("连接正常") or err or _("无法识别服务器响应"))
        end)
    end)
end

---@return fun(iw: number): table
local function libraryRow()
    return function(iw)
        local count = 0
        for _id in pairs(config().libraries or {}) do count = count + 1 end
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "library_books", title = _("书库"),
            status = count > 0 and T(_("%1 个"), count) or _("全部"),
            status_on = true,
            callback = pickLibraries,
        })
    end
end

---@param icon string
---@param title string
---@param callback fun()
---@return fun(iw: number): table
local function action(icon, title, callback)
    return function(iw)
        return require("ui.themes.widgets.row").widget({
            width = iw, kind = "action", icon = icon, title = title, callback = callback,
        })
    end
end

local function importOfficial()
    local account = officialAccount()
    if not account then return end
    local cfg = config()
    cfg.server_url, cfg.username, cfg.userkey = account.server_url, account.username, account.userkey
    save(cfg)
    toast(T(_("已导入账号 %1"), account.username))
end

---@return table[]
function Setting.rows()
    local rows = {
        field("server_url", _("服务器地址"), "https://books.example.com", false, Client.normalizeUrl, "dns"),
        field("username", _("用户名"), _("BookOrbit 设置 → KOReader 里创建的同步账号"), false, Text.trim, "person"),
        field("userkey", _("密码"), _("同步账号的密码"), true, userkey, "key"),
        libraryRow(),
        action("network_check", _("测试连接"), testConnection),
    }
    if officialAccount() then
        table.insert(rows, 1, action("download", _("从 BookOrbit 插件导入账号"), importOfficial))
    end
    return rows
end

--- 远程管理「连接配置」网页上的表单；书库要连服务器挑，仍在设备上选。
Setting.remote = {
    { key = "server_url", label = _("服务器地址"), type = "url", placeholder = "https://books.example.com",
        normalize = Client.normalizeUrl },
    { key = "username", label = _("用户名"), normalize = Text.trim },
    { key = "userkey", label = _("密码"), secret = true, normalize = userkey },
}

return Setting
