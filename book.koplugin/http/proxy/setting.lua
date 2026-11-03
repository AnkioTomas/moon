--[[--
网络设置：KOReader「HTTP 代理」、备选 DNS、解析绑定、超时。

和 KOReader 原生菜单是同一份设置（G_reader_settings 的 http_proxy / http_proxy_enabled），
经 NetworkMgr:setHTTPProxy 生效，插件请求由 http/proxy 读 socket.http.PROXY 走代理。
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
local Text = require("utils.text")
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

--- 经候选代理发一次请求。进度窗不可取消，测试期间顺带挡住重复点按。
---@param url string 规范化的代理地址
---@param cb fun(err: string|nil) err 为 nil 表示代理可用
local function probe(url, cb)
    local loading = require("ui.themes.widgets.progress_dialog"):new{
        title = _("HTTP 代理"), text = _("正在通过代理连接…"), dismissable = false,
    }
    loading:show()
    Request.request({ url = PROBE_URL, proxy = url, timeout = require("http.timeout").net(0.5), connect_timeout = require("http.timeout").net(1 / 3) }, function(_res, err)
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
                return {
                    { title = _("HTTP 代理"), rows = Setting.rows(desktop) },
                    { title = _("DNS"), rows = { Setting.dnsRow(desktop), Setting.bindRow(desktop) } },
                    { title = _("超时"), rows = { Setting.timeoutRow(desktop) } },
                }
            end,
        },
    }
end

--- 「备选 DNS」：每次解析同时问系统 DNS 和这家，谁先应答用谁（见 http/dns.lua）；换家清掉已解析缓存。
---@param desktop BookDesktop
---@return fun(iw: number): table
function Setting.dnsRow(desktop)
    return function(iw)
        local Dns = require("http.dns")
        local current = Dns.current()
        return Row.widget({
            width = iw, kind = "nav", icon = "dns",
            title = _("备选 DNS"),
            subtitle = _("与系统 DNS 同时查询，谁先应答用谁"),
            status = _(current.name), status_on = true,
            callback = function()
                local items = {}
                for _idx, p in ipairs(Dns.PROVIDERS) do
                    items[#items + 1] = {
                        text = _(p.name) .. "  " .. p.servers[1],
                        variant = p.id == current.id and "primary" or "normal",
                        callback = function()
                            local MoonSettings = require("utils.settings")
                            MoonSettings.get("http").dns = p.id
                            MoonSettings.save("http")
                            Dns.clear()
                            desktop:updateView()
                        end,
                    }
                end
                require("ui.themes.widgets.sheet"):new{ title = _("备选 DNS"), items = items }:show()
            end,
        })
    end
end

--- 绑定用的主机名：小写、去掉协议 / 路径 / 端口 / 末尾点。不是域名返回 nil。
---@param raw string
---@return string|nil
local function hostKey(raw)
    local host = Text.trim(raw):lower()
    host = host:gsub("^%a[%w+.-]*://", "")
    host = host:gsub("/.*$", "")
    host = host:gsub(":%d+$", "")
    host = host:gsub("%.$", "")
    if host == "" or #host > 253 or host:find("..", 1, true) or host:sub(1, 1) == "." then
        return nil
    end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return nil end
    for label in host:gmatch("[^.]+") do
        if #label > 63 or label:sub(-1) == "-" or not label:match("^[%w_][%w_%-]*$") then
            return nil
        end
    end
    return host
end

--- 收成四段十进制 IPv4；前导零按十进制吃掉（192.168.001.020 → 192.168.1.20）。
---@param raw string
---@return string|nil
local function ipv4(raw)
    local a, b, c, d = Text.trim(raw):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a or #a > 3 or #b > 3 or #c > 3 or #d > 3 then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return string.format("%d.%d.%d.%d", a, b, c, d)
end

--- IPv6 文本：一组 ``::``、每组 1～4 位十六进制，可带 %zone，可包在方括号里。存小写、不带括号。
---@param raw string
---@return string|nil
local function ipv6(raw)
    local s = Text.trim(raw):lower()
    local inner = s:match("^%[(.+)%]$")
    if inner then s = inner end
    local zone = s:match("%%([%w%._:-]+)$")
    if zone then s = s:sub(1, -(#zone + 2)) end
    local _, doubles = s:gsub("::", "::")
    if doubles > 1 or not s:find(":", 1, true) then return nil end
    local function groups(part)
        if part == "" then return 0 end
        if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return nil end
        local n = 0
        for g in part:gmatch("[^:]+") do
            if not g:match("^%x%x?%x?%x?$") then return nil end
            n = n + 1
        end
        return n
    end
    if doubles == 1 then
        local left, right = s:match("^(.-)::(.*)$")
        local ln, rn = groups(left), groups(right)
        if not ln or not rn or ln + rn >= 8 then return nil end
    elseif groups(s) ~= 8 then
        return nil
    end
    if zone then s = s .. "%" .. zone end
    return s
end

---@param raw string
---@return string|nil
local function parseIp(raw)
    return ipv4(raw) or ipv6(raw)
end

---@return table<string, string>
local function bindMap()
    return require("utils.settings").get("http").dns_bind
end

---@return string[]
local function bindHosts()
    local hosts = {}
    for host, ip in pairs(bindMap()) do
        if type(host) == "string" and type(ip) == "string" and ip ~= "" then
            hosts[#hosts + 1] = host
        end
    end
    table.sort(hosts)
    return hosts
end

local editBind

--- 写入一条绑定。previous 是正在改的旧主机名，改了名就删掉旧键。
---@param desktop BookDesktop
---@param previous string|nil
---@param host string
---@param ip string
local function saveBind(desktop, previous, host, ip)
    local key = hostKey(host)
    if not key then
        editBind(desktop, previous, host, ip)
        Toast:new{ text = _("域名不正确"), timeout = 3 }:show()
        return
    end
    local addr = parseIp(ip)
    if not addr then
        editBind(desktop, previous, host, ip)
        Toast:new{ text = _("地址必须是 IPv4 或 IPv6"), timeout = 3 }:show()
        return
    end
    local map = bindMap()
    if previous and previous ~= key then map[previous] = nil end
    map[key] = addr
    local MoonSettings = require("utils.settings")
    MoonSettings.save("http")
    local Dns = require("http.dns")
    Dns.forget(key)
    if previous then Dns.forget(previous) end
    desktop:updateView()
end

--- 添加（previous 为 nil）或编辑一条绑定。校验失败带着原文重开。
---@param desktop BookDesktop
---@param previous string|nil
---@param host string
---@param ip string
editBind = function(desktop, previous, host, ip)
    Input:new{
        title = previous and _("编辑绑定") or _("添加绑定"),
        fields = {
            { label = _("域名"), text = host, hint = "nas.lan" },
            { label = _("IP 地址"), text = ip, hint = "192.168.1.20" },
        },
        ok_text = _("保存"),
        callback = function(raw_host, raw_ip) saveBind(desktop, previous, raw_host, raw_ip) end,
    }:show()
end

---@param desktop BookDesktop
---@param host string
local function removeBind(desktop, host)
    Confirm:new{
        text = T(_("删除 %1 的解析绑定？"), host),
        ok_text = _("删除"),
        ok_callback = function()
            bindMap()[host] = nil
            require("utils.settings").save("http")
            require("http.dns").forget(host)
            desktop:updateView()
        end,
    }:show()
end

---@param desktop BookDesktop
---@return BookSettingsOverlaySpec
local function bindPage(desktop)
    return {
        title = _("解析绑定"),
        sections = function()
            local map = bindMap()
            local rows = {}
            for _idx, host in ipairs(bindHosts()) do
                local ip = map[host]
                rows[#rows + 1] = function(iw)
                    return Row.widget({
                        width = iw, kind = "nav", icon = "dns",
                        title = host, status = ip, status_on = true,
                        callback = function()
                            require("ui.themes.widgets.sheet"):new{
                                title = host,
                                items = {
                                    { text = _("编辑"), callback = function() editBind(desktop, host, host, ip) end },
                                    { text = _("删除"), callback = function() removeBind(desktop, host) end },
                                },
                            }:show()
                        end,
                    })
                end
            end
            rows[#rows + 1] = function(iw)
                return Row.widget({
                    width = iw, kind = "nav", icon = "add",
                    title = _("添加绑定"),
                    callback = function() editBind(desktop, nil, "", "") end,
                })
            end
            return { { rows = rows } }
        end,
    }
end

--- 「解析绑定」：域名直接对应地址，不再查询 DNS。内网主机用这个，免得公网 DNS 抢先回 NXDOMAIN。
---@param desktop BookDesktop
---@return fun(iw: number): table
function Setting.bindRow(desktop)
    return function(iw)
        local hosts = bindHosts()
        local status, on
        if #hosts == 0 then
            status, on = _("未设置"), false
        elseif #hosts == 1 then
            status, on = hosts[1], true
        else
            status, on = T(_("已绑定 %1 个"), #hosts), true
        end
        return Row.widget({
            width = iw, kind = "nav", icon = "dns",
            title = _("解析绑定"),
            subtitle = _("域名固定到这个地址，不再查询 DNS"),
            status = status, status_on = on,
            callback = function()
                require("desktop.pages.setting.overlay").push(desktop, bindPage(desktop))
            end,
        })
    end
end

--- 「网络超时」：普通请求的默认秒数，其余请求按倍率 × 它（见 http/timeout.lua）。
---@param desktop BookDesktop
---@return fun(iw: number): table
function Setting.timeoutRow(desktop)
    return function(iw)
        local Timeout = require("http.timeout")
        local value = Timeout.networkSeconds()
        return Row.widget({
            width = iw, kind = "nav", icon = "timer",
            title = _("网络超时"),
            subtitle = T(_("普通请求的默认超时；下载等按倍率放大（如下载 %1 秒）"), Timeout.net(10)),
            status = T(_("%1 秒"), value), status_on = true,
            callback = function()
                require("ui.themes.widgets.spin"):new{
                    title = _("网络超时"),
                    fields = { { value = value, min = Timeout.NETWORK_MIN, max = Timeout.NETWORK_MAX, step = Timeout.NETWORK_STEP,
                        format = function(v) return T(_("%1 秒"), v) end } },
                    callback = function(v)
                        Timeout.setNetworkSeconds(v)
                        desktop:updateView()
                    end,
                }:show()
            end,
        })
    end
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
