--[[--
京东读书 HTTP 客户端：只返回 wire，不做领域转换。

@module koplugin.book.source.jdread.client
--]]

local JSON = require("json")
local Protocol = require("source.jdread.protocol")
local Request = require("http.request")
local Text = require("utils.text")
local _ = require("gettext")

local Client = {}
Client.__index = Client

---@class JdreadClient
---@field cookie string|nil
---@field uuid string|nil
---@field configured fun(self: JdreadClient): boolean
---@field shelfSyncAsync fun(self: JdreadClient, cb: function): CancelHandle|nil
---@field bookInfoAsync fun(self: JdreadClient, book_id: string, cb: function): CancelHandle|nil
---@field addToShelfAsync fun(self: JdreadClient, book_id: string, cb: function): CancelHandle|nil
---@field removeFromShelfAsync fun(self: JdreadClient, book_id: string, cb: function): CancelHandle|nil
---@field catalogAsync fun(self: JdreadClient, book_id: string, cb: function): CancelHandle|nil
---@field downloadChapterAsync fun(self: JdreadClient, book_id: string, query: table, cb: function): CancelHandle|nil
---@field getProgressAsync fun(self: JdreadClient, book_id: string, cb: function): CancelHandle|nil
---@field putProgressAsync fun(self: JdreadClient, book_id: string, marker: table, cb: function): CancelHandle|nil

local API = "https://e.m.jd.com"
local CATALOG_PAGE_SIZE = 2000
-- download/chapter 对未购买且非试读章节返回 {"result_code":101,"message":"can not download"}。
local DOWNLOAD_DENIED = 101

---@param raw string|nil
---@return table|nil, string|nil
local function decodeApi(raw, err)
    if not raw then return nil, err end
    local ok, wire = pcall(JSON.decode, raw)
    if not ok or type(wire) ~= "table" then return nil, _("京东读书响应无效") end
    if tonumber(wire.result_code) ~= 0 then
        return nil, wire.message or (_("京东读书错误 ") .. tostring(wire.result_code))
    end
    return wire
end

---@param o table|nil
---@return JdreadClient
function Client:new(o)
    return setmetatable(o or {}, self)
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
    local query = Text.formEncode(Protocol.signedParams(path, self.uuid, extra))
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
    local query = Text.formEncode(Protocol.signedParams(path, self.uuid))
    return Request.post(API .. path .. "?" .. query, JSON.encode(body), {
        headers = self:headers(API .. "/reader/"),
        content_type = "application/json",
    }, function(raw, err)
        cb(decodeApi(raw, err))
    end)
end

--- 拉取完整个人书架。
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:shelfSyncAsync(cb)
    local cancelled, active = false, nil
    local ids, books, index = {}, {}, 1

    local function nextBatch()
        if index > #ids then
            cb({ data = { books = books, total = #ids } })
            return
        end
        local batch = {}
        for i = index, math.min(#ids, index + 17) do
            batch[#batch + 1] = ids[i]
        end
        index = index + #batch
        active = self:apiGetAsync(
            "/jdread/api/ebooks/lite/" .. table.concat(batch, ","),
            nil,
            function(wire, err)
                if cancelled then return end
                if not wire then cb(nil, err); return end
                local page = type(wire.data) == "table" and wire.data or {}
                for _, row in ipairs(page) do books[#books + 1] = row end
                nextBatch()
            end
        )
    end

    active = self:apiGetAsync("/jdread/api/bookshelf/sort", nil, function(wire, err)
        if cancelled then return end
        if not wire then cb(nil, err); return end
        local data = type(wire.data) == "table" and wire.data or {}
        local seen = {}
        for _, row in ipairs(data.book_ids or {}) do
            local id = type(row) == "table" and row.ebook_id or row
            id = id ~= nil and tostring(id) or nil
            if id and id ~= "" and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
        nextBatch()
    end)
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
end

--- 拉取书籍元数据。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:bookInfoAsync(book_id, cb)
    local path = "/jdread/api/ebook/lite/" .. tostring(book_id)
    return self:apiGetAsync(path, nil, cb)
end

--- 搜索京东书城。直连 e.m.jd.com，不依赖浏览器 h5st 风控运行时。
---@param keyword string
---@param page integer|nil
---@param page_size integer|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:searchAsync(keyword, page, page_size, cb)
    local cancelled, active = false, nil
    local current = math.max(1, math.floor(tonumber(page) or 1))
    local wanted = math.max(1, math.floor(tonumber(page_size) or 20))
    local size, books = math.min(wanted, 30), {}

    local function nextPage()
        active = self:apiGetAsync("/jdread/api/search/v2", {
            keyword = keyword,
            order_by = "",
            page = current,
            page_size = size,
            cv = "3.4.0",
        }, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local data = type(wire.data) == "table" and wire.data or {}
            local rows = data.product_search_infos or {}
            for _, row in ipairs(rows) do
                if #books >= wanted then break end
                books[#books + 1] = row
            end
            local total = tonumber(data.total_count) or #books
            if #rows > 0 and #books < wanted and current * size < total then
                current = current + 1
                nextPage()
            else
                cb({
                    data = {
                        product_search_infos = books,
                        total_count = total,
                    },
                    result_code = 0,
                    message = wire.message,
                })
            end
        end)
    end
    nextPage()
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end }
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
            { action = action, ebook_id = tonumber(book_id) or tostring(book_id) },
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
    local cancelled, active = false, nil
    local rows = {}

    local function nextPage()
        active = self:apiGetAsync(path, { page_size = CATALOG_PAGE_SIZE, index = #rows }, function(wire, err)
            if cancelled then return end
            if not wire then cb(nil, err); return end
            local data = type(wire.data) == "table" and wire.data or {}
            local page = type(data.chapter_info) == "table" and data.chapter_info or {}
            for _, row in ipairs(page) do rows[#rows + 1] = row end
            if data.has_more and #page > 0 then
                nextPage()
                return
            end
            data.chapter_info = rows
            wire.data = data
            cb(wire)
        end)
    end
    nextPage()
    return { cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
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
    local signed = Protocol.signedParams(path, self.uuid, nil, tm)
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
        { ebook_id = tonumber(book_id) or tostring(book_id), format = 1 },
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
            ebook_id = tostring(book_id),
            format = 1,
            list = { marker },
        },
    }, cb)
end

return Client
