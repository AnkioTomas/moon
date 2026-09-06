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

local API = "https://e.m.jd.com"
local READER = "https://cread.jd.com"

---@param raw string|nil
---@param err any
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
    o = o or {}
    o._read_types = {}
    return setmetatable(o, self)
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
        local wire, decode_err = decodeApi(raw, err)
        cb(wire, decode_err)
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
        local wire, decode_err = decodeApi(raw, err)
        cb(wire, decode_err)
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
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
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
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

--- 拉取指定书籍的相关推荐。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:recommendAsync(book_id, cb)
    local path = "/jdread/api/ebook/" .. tostring(book_id) .. "/recommend"
    return self:apiGetAsync(path, nil, cb)
end

--- 将书城书籍加入京东书架。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:addToShelfAsync(book_id, cb)
    return self:apiPostAsync("/jdread/api/bookshelf/book/sync", {
        version = os.time() * 1000,
        first_sync = 1,
        items = {
            { action = 0, ebook_id = tonumber(book_id) or tostring(book_id) },
        },
    }, cb)
end

---@param endpoint string
---@param query table
---@param cb fun(data: table|nil, err: string|nil, retryable: boolean|nil)
---@return { cancel: fun() }
function Client:readerGetAsync(endpoint, query, cb)
    return Request.get(READER .. endpoint .. "?" .. Text.formEncode(query), {
        headers = self:headers(READER .. "/read/index.action"),
    }, function(raw, err)
        if not raw then cb(nil, err); return end
        local wire, decode_err, retryable = Protocol.decodeEnvelope(raw)
        cb(wire, decode_err, retryable)
    end)
end

---@param endpoint string
---@param book_id string|number
---@param key string
---@param extra table|nil
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:readerAutoAsync(endpoint, book_id, key, extra, cb)
    book_id = tostring(book_id)
    local modes, seen = {}, {}
    local cached = self._read_types[book_id]
    local function add(mode)
        if mode ~= nil and not seen[mode] then
            seen[mode] = true
            modes[#modes + 1] = mode
        end
    end
    add(cached)
    add(3)
    add(0)
    add(1)

    local cancelled, active, index = false, nil, 1
    local function attempt(last_err)
        if cancelled then return end
        local mode = modes[index]
        if mode == nil then cb(nil, last_err or _("京东读书无可用阅读权限")); return end
        index = index + 1
        local query = { k = key, readType = mode, orderId = "" }
        for name, value in pairs(extra or {}) do query[name] = value end
        active = self:readerGetAsync(endpoint, query, function(wire, err, retryable)
            if cancelled then return end
            if wire then
                self._read_types[book_id] = mode
                cb(wire)
            elseif retryable then
                attempt(err)
            else
                cb(nil, err)
            end
        end)
    end
    attempt()
    return {
        cancel = function()
            cancelled = true
            if active and active.cancel then active.cancel() end
        end,
    }
end

--- 拉取旧阅读器目录。
---@param book_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:chapterInfosAsync(book_id, cb)
    return self:readerAutoAsync("/read/lC.action", book_id, Protocol.bookKey(book_id), {
        bookId = tostring(book_id),
    }, cb)
end

--- 拉取旧阅读器章节正文。
---@param book_id string|number
---@param chapter_id string|number
---@param cb fun(data: table|nil, err: string|nil)
---@return { cancel: fun() }
function Client:chapterContentAsync(book_id, chapter_id, cb)
    return self:readerAutoAsync(
        "/read/gC.action",
        book_id,
        Protocol.chapterKey(book_id, chapter_id),
        nil,
        cb
    )
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
