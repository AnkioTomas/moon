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

--- 请求超时（秒）：全量书架（all-v2）在慢设备 / 慢服务器上一次要几十秒，
--- 硬上限会让整轮同步中断、书架永远加载不出来。留个设置行按设备调大。
---@return fun(iw: number): table
local function timeoutRow()
    return function(iw)
        local client = require("moonsource_kavita.client")
        local value = tonumber(config().timeout) or client.DEFAULT_TIMEOUT
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "hourglass_top", title = _("请求超时"),
            status = T(_("%1 秒"), value),
            status_on = value ~= client.DEFAULT_TIMEOUT,
            callback = function()
                local cfg = config()
                require("ui.themes.widgets.input"):new{
                    title = _("请求超时"),
                    fields = { {
                        text = tostring(tonumber(cfg.timeout) or client.DEFAULT_TIMEOUT),
                        hint = _("秒，慢设备 / 慢服务器调大"),
                        input_type = "number",
                    } },
                    ok_text = _("保存"),
                    callback = function(input)
                        local seconds = math.floor(tonumber(input) or 0)
                        -- 空 / 非正数回默认值；正数交给 Client 收敛到合法区间（5–600）。
                        cfg.timeout = seconds > 0 and seconds or nil
                        save(cfg)
                    end,
                }:show()
            end,
        })
    end
end

--- 进度心跳间隔（秒）：Kavita 的阅读会话时长 = 相邻两次进度写入的间隔，只在关书推一次会是
--- 0 秒会话；阅读期按这个间隔补推当前位置。0 = 关闭（关书 / 切章 / 休眠的推送不受影响）。
---@return fun(iw: number): table
local function heartbeatRow()
    return function(iw)
        local Source = require("moonsource_kavita.source")
        local default = Source.DEFAULT_HEARTBEAT_INTERVAL
        local value = tonumber(config().heartbeat_interval) or default
        return require("ui.themes.widgets.row").widget({
            width = iw, chevron = true,
            kind = "nav", icon = "favorite", title = _("进度心跳间隔"),
            -- 行副标题是单行截断的（TextWidget 带 max_width 不换行），这行还有状态与箭头，
            -- 右边留给文字的位置很窄：副标题必须短，长解释放不进来。
            subtitle = _("阅读时补推进度，0 关闭"),
            status = value > 0 and T(_("%1 秒"), value) or _("已关闭"),
            status_on = value > 0,
            callback = function()
                local cfg = config()
                require("ui.themes.widgets.input"):new{
                    title = _("进度心跳间隔"),
                    fields = { {
                        text = tostring(tonumber(cfg.heartbeat_interval) or default),
                        hint = _("秒，0 = 关闭；Kavita 按写入间隔算阅读时长"),
                        input_type = "number",
                    } },
                    ok_text = _("保存"),
                    callback = function(input)
                        local seconds = tonumber(input)
                        -- 空 / 非数字回默认值；0（或负数）交给源当成关闭。
                        if not seconds or seconds < 0 then
                            cfg.heartbeat_interval = nil
                        else
                            cfg.heartbeat_interval = math.floor(seconds)
                        end
                        save(cfg)
                    end,
                }:show()
            end,
        })
    end
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
        heartbeatRow(),
        timeoutRow(),
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
