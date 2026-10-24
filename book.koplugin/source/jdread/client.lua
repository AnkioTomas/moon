--[[--
京东读书 HTTP 客户端：只返回 wire，不做领域转换。

@module koplugin.book.source.jdread.client
--]]

local JSON = require("json")
local Protocol = require("source.jdread.protocol")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

---@class JdreadClient
---@field cookie string|nil
---@field uuid string|nil
local Client = {}
Client.__index = Client

local API = "https://e.m.jd.com"
local CATALOG_PAGE_SIZE = 2000
-- ebooks/lite 每次最多取的书数。
local SHELF_BATCH = 18
-- download/chapter 对未购买且非试读章节返回 {"result_code":101,"message":"can not download"}。
local DOWNLOAD_DENIED = 101

---@param raw string|nil
---@return table|nil, string|nil
local function decodeApi(raw, err)
    if not raw then return nil, err end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("京东读书响应无效") end
    if tonumber(wire.result_code) ~= 0 then
        -- 网页 Cookie 没有续期接口：提示含「登录」即视为会话失效，由上层引导重新扫码。
        if tostring(wire.message or ""):find("登录", 1, true) then
            return nil, require("source.auth").expire("jdread", wire.message)
        end
        return nil, wire.message or (_("京东读书错误 ") .. tostring(wire.result_code))
    end
    require("source.auth").ok("jdread")
    return wire
end

---@param o { cookie: string|nil, uuid: string|nil }
---@return JdreadClient
function Client:new(o)
    return setmetatable(o, self)
end

--- 签名用的 uuid：没登录也要能逛榜单，缺省用设备派生值（登录时存的也是它）。
---@return string
function Client:signUuid()
    if type(self.uuid) == "string" and self.uuid ~= "" then return self.uuid end
    return "h5" .. require("ffi/sha2").md5(require("utils.device_id").ensure())
end

---@return boolean
function Client:configured()
    return type(self.cookie) == "string" and self.cookie ~= ""
        and type(self.uuid) == "string" and self.uuid ~= ""
end

---@param referer string
---@return table
function Client:headers(referer)
    return {
        ["Cookie"] = self.cookie,
        ["Referer"] = referer,
        ["Origin"] = "https://e.m.jd.com",
        ["Accept"] = "application/json, text/plain, */*",
    }
end

---@param path string
---@param extra table|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:apiGetAsync(path, extra, cb)
    local query = Text.formEncode(Protocol.signedParams(path, self:signUuid(), extra))
    return Request.get(API .. path .. "?" .. query, {
        headers = self:headers(API .. "/"),
    }, function(raw, err)
        cb(decodeApi(raw, err))
    end)
end

---@param path string
---@param body table
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:apiPostAsync(path, body, cb)
    local query = Text.formEncode(Protocol.signedParams(path, self:signUuid()))
    return Request.post(API .. path .. "?" .. query, JSON.encode(body), {
        headers = self:headers(API .. "/reader/"),
        content_type = "application/json",
    }, function(raw, err)
        cb(decodeApi(raw, err))
    end)
end

--- 拉取完整个人书架，回调 ebooks/lite 行数组。
---@param cb fun(rows: table[]|nil, err: string|nil)
---@return { cancel: fun() }
function Client:shelfSyncAsync(cb)
    local cancelled, active = false, nil
    local ids, books, index = {}, {}, 1

    local function nextBatch()
        if index > #ids then
            cb(books)
            return
        end
        local batch = {}
        for i = index, math.min(#ids, index + SHELF_BATCH - 1) do
            batch[#batch + 1] = ids[i]
        end
        index = index + #batch
        local mine = index
        local handle = self:apiGetAsync(
            "/jdread/api/ebooks/lite/" .. table.concat(batch, ","),
            nil,
            function(wire, err)
                if cancelled then return end
                if not wire then cb(nil, err); return end
                local page = type(wire.data) == "table" and wire.data or {}
                for _idx, row in ipairs(page) do books[#books + 1] = row end
                nextBatch()
            end
        )
        -- 回调同步触发时已发出下一个请求，不能用旧句柄覆盖它（同 http/mirror）。
        if index == mine then active = handle end
    end

    local first = self:apiGetAsync("/jdread/api/bookshelf/sort", nil, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local data = type(wire.data) == "table" and wire.data or {}
        local seen = {}
        for _idx, row in ipairs(data.book_ids or {}) do
            local id = type(row) == "table" and row.ebook_id or row
            id = id ~= nil and tostring(id) or nil
            if id and id ~= "" and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
        nextBatch()
    end)
    -- 同步回包时 nextBatch 已登记了分批请求，不能用书架排序的旧句柄覆盖。
    if not active then active = first end
    return { cancel = function()
            cancelled = true
            active.cancel()
        end }
end

--- 关键词搜索（不带 order_by，网页端带分号的排序值需要特殊编码）。
---@param keyword string
---@param page integer
---@param page_size integer
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:searchAsync(keyword, page, page_size, cb)
    return self:apiGetAsync("/jdread/api/search/v2", {
        keyword = keyword, page = page, page_size = page_size, cv = "3.4.0",
    }, cb)
end

--- 榜单菜单：出版 / 男生 / 女生，每类下是榜单及其周期。
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:rankTypesAsync(cb)
    return self:apiGetAsync("/jdread/api/rank/type", nil, cb)
end

--- 分类树：根节点按出版 / 男生原创 / 女生原创分开，榜单的 catid 只认根下一级。
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:categoriesAsync(cb)
    return self:apiGetAsync("/jdread/api/category", nil, cb)
end

--- 榜单一页；catid 为空表示不按分类筛。
---@param kind string|number
---@param period string week / mouth / all（京东原拼写）
---@param catid string|nil
---@param page integer
---@param page_size integer
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:rankAsync(kind, period, catid, page, page_size, cb)
    return self:apiGetAsync("/jdread/api/rank/" .. tostring(kind), {
        period = period,
        catid = catid ~= "" and catid or nil,
        page = page,
        page_size = page_size,
    }, cb)
end

--- 拉取书籍元数据。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:bookInfoAsync(book_id, cb)
    local path = "/jdread/api/ebook/lite/" .. tostring(book_id)
    return self:apiGetAsync(path, nil, cb)
end

--- 书架同步协议：action=0 加入，action=1 移除（与官方客户端一致）。
---@param client JdreadClient
---@param book_id string|number
---@param action integer
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
local function shelfActionAsync(client, book_id, action, cb)
    return client:apiPostAsync("/jdread/api/bookshelf/book/sync", {
        version = os.time() * 1000,
        first_sync = 1,
        items = {
            { action = action, ebook_id = tonumber(book_id) },
        },
    }, cb)
end

--- 将书城书籍加入京东书架。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:addToShelfAsync(book_id, cb)
    return shelfActionAsync(self, book_id, 0, cb)
end

--- 从京东书架移除。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:removeFromShelfAsync(book_id, cb)
    return shelfActionAsync(self, book_id, 1, cb)
end

--- 拉取完整目录（与网页阅读器同一 v2 接口，index 为行偏移分页）。
--- EPUB / 会员书 / txt 网文都走这条。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:catalogAsync(book_id, cb)
    local path = "/jdread/api/ebook/catalog/v2/" .. tostring(book_id)
    local cancelled, rows = false, {}
    ---@type { cancel: fun() }
    local active

    local seq = 0
    local function nextPage()
        seq = seq + 1
        local mine = seq
        local handle = self:apiGetAsync(path, { page_size = CATALOG_PAGE_SIZE, index = #rows }, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local data = type(wire.data) == "table" and wire.data or {}
            local page = type(data.chapter_info) == "table" and data.chapter_info or {}
            for _idx, row in ipairs(page) do rows[#rows + 1] = row end
            if data.has_more and #page > 0 then
                nextPage()
                return
            end
            data.chapter_info = rows
            wire.data = data
            cb(wire)
        end)
        -- 回调同步触发时已发出下一个请求，不能用旧句柄覆盖它（同 http/mirror）。
        if seq == mine then active = handle end
    end
    nextPage()
    return { cancel = function()
            cancelled = true
            active.cancel()
        end }
end

--- 拉取章节正文。EPUB 传 { indexes = 0-based 序号 }，txt 网文传 { type = 1, ids = chapter_id }。
---@param book_id string|number
---@param query table
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:downloadChapterAsync(book_id, query, cb)
    local path = "/jdread/api/download/chapter/" .. tostring(book_id)
    local tm = Protocol.evenTime()
    local signed = Protocol.signedParams(path, self:signUuid(), nil, tm)
    local params = {
        enc = 1,
        app = "jdread-m",
        tm = tm,
        params = Protocol.encryptQuery(Text.formEncode(signed), tm),
    }
    for key, value in pairs(query) do params[key] = value end
    return Request.get(API .. path .. "?" .. Text.formEncode(params), {
        headers = self:headers(API .. "/reader/"),
    }, function(raw, err)
        if not raw then cb(nil, err); return end
        local wire, decode_err, code = Protocol.decodeDownload(raw, tm)
        if code == DOWNLOAD_DENIED then decode_err = _("京东读书网页协议读不到本章，请在京东读书 App 内阅读") end
        cb(wire, decode_err)
    end)
end

--- 拉取云端阅读位置。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:getProgressAsync(book_id, cb)
    return self:apiPostAsync("/jdread/api/marker/sync", {
        { ebook_id = tonumber(book_id), format = 1 },
    }, cb)
end

--- 覆盖云端阅读位置。
---@param book_id string|number
---@param marker table
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:putProgressAsync(book_id, marker, cb)
    return self:apiPostAsync("/jdread/api/marker/sync", {
        {
            version = 0,
            ebook_id = tonumber(book_id),
            format = 1,
            list = { marker },
        },
    }, cb)
end

return Client
