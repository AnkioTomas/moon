--[[--
Kavita 源设置：服务器地址、API Key、书库选择、测试连接。
配置经月读 utils.settings.getSource / saveSource("ext.kavita") 落盘。

@module moonsource_kavita.setting
--]]

local Text = require("utils.text")
local _ = require("gettext")
local T = require("ffi/util").template

local ID = "ext.kavita"

local Setting = {}

---@return table
local function config()
    return require("utils.settings").getSource(ID)
end

--- 落盘并重建源实例，让新地址 / Key / 书库立即生效，设置页随之刷新。
---@param cfg table
local function save(cfg)
    require("utils.settings").saveSource(ID, cfg)
    require("source.registry").reload()
end

---@param text string
local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = 3 }:show()
end

--- 未配置 / 断网当场提示；否则带忙碌提示调 fn(client, done)，fn 结束时必须调 done()。
---@param fn fun(client: KavitaClient, done: fun())
local function withServer(fn)
    local client = require("moonsource_kavita.client").new(config())
    if not client:configured() then
        toast(_("请先填写服务器地址和 API Key"))
        return
    end
    if not require("ui/network/manager"):isConnected() then
        toast(_("网络不可用，请先连接 Wi-Fi"))
        return
    end
    local busy = require("ui.themes.widgets.toast"):new{ text = _("正在连接 Kavita…"), dismissable = false }
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
                    fields = { { text = cfg[key] or "", hint = hint, text_type = password and "password" or nil } },
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

--- 多选书库：只同步选中的库，书架分类即库名。
local function pickLibraries()
    withServer(function(client, done)
        client:json("GET", "/api/Library/libraries", nil, nil, function(libraries, err)
            done()
            if not libraries then
                toast(err)
                return
            end
            local cfg = config()
            local chosen = cfg.libraries or {}
            local items = {}
            for _idx, lib in ipairs(libraries) do
                local id = tostring(lib.id)
                items[#items + 1] = { text = lib.name or id, value = id, checked = chosen[id] == true }
            end
            require("ui.themes.widgets.list"):new{
                title = _("选择书库"),
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
        client:request("GET", "/api/Plugin/version", { apiKey = client.api_key }, nil, function(version, err)
            done()
            local major, minor = (version or ""):match("^(%d+)%.(%d+)")
            if not major then
                toast(err or _("无法识别 Kavita 版本"))
            elseif tonumber(major) == 0 and tonumber(minor) < 9 then
                toast(T(_("Kavita %1 过旧，需要 0.9 及以上"), Text.trim(version)))
            else
                toast(T(_("连接正常，Kavita %1"), Text.trim(version)))
            end
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
            status = count > 0 and T(_("%1 个"), count) or _("未选择"),
            status_on = count > 0,
            callback = pickLibraries,
        })
    end
end

---@return fun(iw: number): table
local function testRow()
    return function(iw)
        return require("ui.themes.widgets.row").widget({
            width = iw,
            kind = "action", icon = "network_check", title = _("测试连接"),
            callback = testConnection,
        })
    end
end

---@param value string|nil
---@return string
local function normalizeUrl(value)
    return Text.rtrimSlashes(Text.stripWhitespace(value))
end

---@return table[]
function Setting.rows()
    return {
        field("base_url", _("服务器地址"), "https://kavita.example.com", false, normalizeUrl, "dns"),
        field("api_key", _("API Key"), _("Kavita 用户设置 → API Key"), true, Text.stripWhitespace, "key"),
        libraryRow(),
        testRow(),
    }
end

--- 远程管理「连接配置」网页上的表单；书库要连服务器挑，仍在设备上选。
Setting.remote = {
    { key = "base_url", label = _("服务器地址"), type = "url", placeholder = "https://kavita.example.com",
        normalize = normalizeUrl },
    { key = "api_key", label = _("API Key"), secret = true, normalize = Text.stripWhitespace },
}

return Setting
