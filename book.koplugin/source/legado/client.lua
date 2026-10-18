--[[--
阅读（Legado）Web 服务 HTTP 客户端（仅异步）。

用户在阅读 App 里打开「Web 服务」，月读直连局域网地址（如 http://192.168.1.8:1122）。
回包是 `{ isSuccess, errorMsg, data }`；章节序号一律是 0 基的 `index`。

@module koplugin.book.source.legado.client
--]]

local JSON = require("json")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}

local SOURCE_ID = "legado"

--- 服务器地址，缺协议头按 http 补；没配置返回 nil。
---@return string|nil
function Client.base()
    local addr = require("utils.settings").getSource(SOURCE_ID).server_address
    if type(addr) ~= "string" or addr == "" then return nil end
    if not addr:match("^https?://") then addr = "http://" .. addr end
    return (addr:gsub("/+$", ""))
end

--- 解回包：isSuccess 为真才算成功，返回 data。
---@param raw string|nil
---@param err any
---@return any|nil data, string|nil err
function Client.decode(raw, err)
    if not raw then return nil, err and tostring(err) or _("请求失败") end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("响应无效") end
    if not wire.isSuccess then return nil, wire.errorMsg ~= "" and wire.errorMsg or _("请求失败") end
    if wire.data == nil then return {} end
    return wire.data
end

---@param path string
---@param query table<string, any>|nil
---@return string|nil
local function url(path, query)
    local base = Client.base()
    if not base then return nil end
    local out = base .. path
    if query then
        local qs = Text.formEncode(query)
        if qs ~= "" then out = out .. "?" .. qs end
    end
    return out
end

---@param path string
---@param query table<string, any>|nil
---@param ratio number 超时倍率
---@param cb fun(data: any|nil, err: string|nil)
---@return { cancel: fun() }
local function get(path, query, ratio, cb)
    local target = url(path, query)
    if not target then return require("source.base").defer(cb, nil, _("未配置阅读服务器地址")) end
    return Request.get(target, {
        accept = "application/json",
        timeout = require("http.timeout").net(ratio),
    }, function(raw, err) cb(Client.decode(raw, err)) end)
end

---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.shelfAsync(cb)
    return get("/getBookshelf", { refresh = 0 }, 0.5, function(data, err)
        if type(data) ~= "table" then cb(nil, err); return end
        cb(data)
    end)
end

---@param book_url string
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client.chaptersAsync(book_url, cb)
    return get("/getChapterList", { url = book_url }, 1, function(data, err)
        if type(data) ~= "table" then cb(nil, err); return end
        cb(data)
    end)
end

--- 一章正文（0 基序号），纯文本。
---@param book_url string
---@param index integer
---@param cb fun(text: string|nil, err: string|nil)
---@return { cancel: fun() }
function Client.contentAsync(book_url, index, cb)
    return get("/getBookContent", { url = book_url, index = index }, 1, function(data, err)
        if type(data) ~= "string" or data == "" then
            require("utils.log").warn("legado empty chapter", book_url, index, type(data), err)
            cb(nil, err or (_("阅读章节内容为空") .. " #" .. (index + 1)))
            return
        end
        cb(data)
    end)
end

---@param path string
---@param body table
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
local function post(path, body, cb)
    local target = url(path)
    if not target then return require("source.base").defer(cb, nil, _("未配置阅读服务器地址")) end
    return Request.post(target, JSON.encode(body), {
        accept = "application/json",
        content_type = "application/json",
        timeout = require("http.timeout").net(0.5),
    }, function(raw, err)
        local _data, reason = Client.decode(raw, err)
        cb(reason == nil or nil, reason)
    end)
end

--- 上报阅读位置。row 是书架原行（name / author / bookUrl）。
---@param row table
---@param pos { index: integer, title: string|nil, offset: integer }
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.saveProgressAsync(row, pos, cb)
    return post("/saveBookProgress", {
        name = row.name,
        author = row.author,
        url = row.bookUrl,
        index = pos.index,
        durChapterIndex = pos.index,
        durChapterPos = pos.offset,
        durChapterTitle = pos.title or "",
        durChapterTime = os.time() * 1000,
    }, cb)
end

--- 把书从阅读 App 书架移除，row 是书架原行。
---@param row table
---@param cb fun(ok: boolean|nil, err: string|nil)
---@return { cancel: fun() }
function Client.deleteBookAsync(row, cb)
    return post("/deleteBook", row, cb)
end

return Client
