--[[--
扩展接口路由：功能模块经 `web.routes` 挂点（见 utils/extension.lua）把自己的网页挂进远程管理，远程管理不认识任何具体功能。

提供者 { name, dir?, assets?, page?, l10n?, handle, download? }：
- /api/<name>/<action>：只读的 GET 带 query；有副作用的一律 POST（JSON body）。download(action) 给出附件时直接回文本下载，
  其余交给 handle(method, action, params, cb(status, table))，连接转 pending 等回调，回调只认第一次。
- assets：dir 目录下随之开放的静态文件名（/<文件名>）。
- page：{ href, title, title_long?, desc?, icon（svg path）, tile? }，经 /api/pages 补进顶栏与首页。
- l10n：网页文案模块前缀，按语言 require(l10n .. "." .. lang) 合入 /api/i18n。

@module koplugin.book.features.remote.ext_route
--]]

local JSON = require("json")
local Ext = require("utils.extension")

local ExtRoute = {}

ExtRoute.TEXT_LIMIT = 1024 * 1024

local CTYPE = {
    html = "text/html; charset=utf-8",
    js = "application/javascript; charset=utf-8",
    css = "text/css; charset=utf-8",
    png = "image/png",
    svg = "image/svg+xml",
}

--- 按名字取提供者。
---@param name string
---@return table|nil
function ExtRoute.find(name)
    for _idx, item in ipairs(Ext.list("web.routes")) do
        if item.name == name then return item end
    end
end

--- 提供者开放的静态文件：path → { 文件名, ctype, 绝对路径 }；不是返回 nil。
---@param path string 形如 /page.html
---@return table|nil
function ExtRoute.asset(path)
    local name = path:match("^/([%w_%-]+%.[%w]+)$")
    if not name then return nil end
    local ext = name:match("%.(%w+)$")
    if not CTYPE[ext] then return nil end
    for _idx, item in ipairs(Ext.list("web.routes")) do
        for _i, asset in ipairs(item.assets or {}) do
            if asset == name and item.dir then return { name, CTYPE[ext], item.dir .. "/" .. name } end
        end
    end
end

--- 登记的页面入口（/api/pages）。
---@return table[]
function ExtRoute.pages()
    local out = {}
    for _idx, item in ipairs(Ext.list("web.routes")) do
        local p = item.page
        if type(p) == "table" and p.href then
            out[#out + 1] = { href = p.href, title = p.title, title_long = p.title_long, desc = p.desc, icon = p.icon, tile = p.tile }
        end
    end
    return out
end

--- 各提供者某语言的网页文案表。
---@param lang string
---@return table[]
function ExtRoute.l10n(lang)
    local out = {}
    for _idx, item in ipairs(Ext.list("web.routes")) do
        if item.l10n then
            local ok, t = pcall(require, item.l10n .. "." .. lang)
            if ok and type(t) == "table" then out[#out + 1] = t end
        end
    end
    return out
end

local function dispatch(self, conn, item, method, action, params)
    conn.state = "pending"
    local answered = false
    item.handle(method, action, params, function(status, result, extra)
        if answered or conn.dead then return end
        answered = true
        conn.resp = self.jsonResp(status, JSON.encode(result or {}))
        if extra then conn.resp.extra = extra end
    end)
end

---@param conn table
---@param method string
---@param headers table
---@param query table
---@param item table 提供者
---@param action string
function ExtRoute.route(self, conn, method, headers, query, item, action)
    if method == "GET" then
        local file = item.download and item.download(action)
        if file then
            return self:_queueResponse(conn, { code = 200, ctype = file.ctype,
                extra = { 'Content-Disposition: attachment; filename="' .. file.filename .. '"' },
                body = file.body })
        end
        return dispatch(self, conn, item, "GET", action, query or {})
    end
    if method ~= "POST" then return self:_fail(conn, 405, "Method Not Allowed") end
    return self:_acceptJson(conn, headers, ExtRoute.TEXT_LIMIT, function(server, c, body)
        return dispatch(server, c, item, "POST", action, body)
    end)
end

return ExtRoute
