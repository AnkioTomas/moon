--[[--
网络设置：KOReader「HTTP 代理」的主题版入口。

和 KOReader 原生菜单是同一份设置（G_reader_settings 的 http_proxy / http_proxy_enabled），
经 NetworkMgr:setHTTPProxy 生效，插件请求由 http.proxy 读 socket.http.PROXY 走代理。
只支持明文 http:// 代理；保存前校验格式并经该代理实测一次。

@module koplugin.book.http.proxy.setting
--]]

require("l10n").apply()

local NetworkMgr = require("ui/network/manager")
local Confirm = require("ui.themes.widgets.confirm")
local Input = require("ui.themes.widgets.input")
local Row = require("ui.themes.widgets.row")
local Toast = require("ui.themes.widgets.toast")
local Request = require("http.request")
local Proxy = require("http.proxy")
local _ = require("gettext")
local T = require("ffi/util").template

local Setting = {}

--- 实测走 https，顺带验证 CONNECT 隧道；收到任何 HTTP 应答都算代理可用。
local PROBE_URL = require("online.base").host .. "/"

--- 已存地址原文，也是编辑框预填；未设置时给 http://（本身解析不过，saved() 为 nil）。
---@return string
local function savedText()
    local raw = G_reader_settings:readSetting("http_proxy")
    return type(raw) == "string" and raw ~= "" and raw or "http://"
end

---@return BookHttpProxy|nil
local function saved()
    return (Proxy.parse(savedText()))
end

---@return boolean
local function enabled()
    return G_reader_settings:isTrue("http_proxy_enabled")
end

--- 启用（url）或关闭（nil）代理并刷新设置页。
---@param desktop BookDesktop
---@param url string|nil
local function use(desktop, url)
    NetworkMgr:setHTTPProxy(url)
    desktop:updateView()
end

--- 经候选代理发一次请求。提示窗不可点掉，测试期间顺带挡住重复点按。
---@param url string 规范化的代理地址
---@param cb fun(err: string|nil) err 为 nil 表示代理可用
local function probe(url, cb)
    local loading = Toast:new{ text = _("正在通过代理连接…"), dismissable = false }
    loading:show()
    Request.request({ url = PROBE_URL, proxy = url, timeout = 15, connect_timeout = 10 }, function(_res, err)
        loading:close()
        cb(err and tostring(err) or nil)
    end)
end

local edit

--- 保存：空串清除并关闭代理；格式错提示后带原文重开；连不通时确认是否仍然保存。
---@param desktop BookDesktop
---@param raw string
local function submit(desktop, raw)
    if raw:match("^%s*$") then
        G_reader_settings:delSetting("http_proxy")
        return use(desktop, nil)
    end
    local proxy, err = Proxy.parse(raw)
    if not proxy then
        edit(desktop, raw)
        Toast:new{ text = err, timeout = 3 }:show()
        return
    end
    local function save() use(desktop, proxy.url) end
    probe(proxy.url, function(probe_err)
        if not probe_err then
            save()
            Toast:new{ text = _("代理可用，已保存并启用"), timeout = 2 }:show()
            return
        end
        Confirm:new{
            text = T(_("代理不可用：%1\n仍要保存并启用吗？"), probe_err),
            ok_text = _("仍然保存"),
            ok_callback = save,
        }:show()
    end)
end

--- 编辑代理地址；「测试」不关窗只实测。
---@param desktop BookDesktop
---@param text string 预填内容
edit = function(desktop, text)
    Input:new{
        title = _("HTTP 代理"),
        fields = { { text = text, hint = "http://192.168.1.2:8080" } },
        ok_text = _("保存"),
        actions = { {
            text = _("测试"),
            callback = function(raw)
                local proxy, err = Proxy.parse(raw)
                if not proxy then
                    Toast:new{ text = err, timeout = 3 }:show()
                    return
                end
                probe(proxy.url, function(probe_err)
                    local msg = probe_err and T(_("代理不可用：%1"), probe_err) or _("代理可用")
                    Toast:new{ text = msg, timeout = 3 }:show()
                end)
            end,
        } },
        callback = function(raw) submit(desktop, raw) end,
    }:show()
end

--- 开关：关掉保留地址；打开时已存地址合法直接启用，否则先去填地址。
---@param desktop BookDesktop
local function toggle(desktop)
    if enabled() then
        return use(desktop, nil)
    end
    local proxy = saved()
    if not proxy then
        return edit(desktop, savedText())
    end
    use(desktop, proxy.url)
end

--- 设置根页的导航条目（BookSettingEntry，group 与 order 由设置页填）。
---@param desktop BookDesktop
---@return table
function Setting.entry(desktop)
    local proxy, on = saved(), enabled()
    return {
        id = "network",
        icon = "lan",
        title = _("网络"),
        subtitle = _("HTTP 代理"),
        status = on and proxy and (proxy.host .. ":" .. proxy.port) or _("直连"),
        status_on = on and proxy ~= nil,
        page = {
            title = _("网络"),
            sections = function()
                return { { title = _("HTTP 代理"), rows = Setting.rows(desktop) } }
            end,
        },
    }
end

---@param desktop BookDesktop
---@return (fun(iw: number): table)[]
function Setting.rows(desktop)
    local proxy, on = saved(), enabled()
    return {
        function(iw)
            return Row.widget({
                width = iw, chevron = false, kind = "toggle", icon = "lan",
                title = _("使用 HTTP 代理"),
                subtitle = _("只支持 http:// 代理，HTTPS 请求经隧道转发"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function() toggle(desktop) end,
            })
        end,
        function(iw)
            return Row.widget({
                width = iw, chevron = true, kind = "nav", icon = "edit",
                title = _("代理地址"),
                status = proxy and (proxy.host .. ":" .. proxy.port) or _("未设置"),
                status_on = proxy ~= nil,
                callback = function() edit(desktop, savedText()) end,
            })
        end,
    }
end

return Setting
