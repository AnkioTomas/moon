--[[--
书城数据获取层缓存：各源 browseAsync / searchAsync 的结果统一在这里读穿，
源只负责拉数据，缓存与新鲜度只由这一份 TTL 管，不再钻进各源 client。

键是数据身份（源 + 节点 / 关键词），不是请求 URL：签名参数（京东 tm）、各源私有
请求形状都挡不住。值只存有序 stable_id 与 groups，书的元数据从 books 表解析
（唯一真相），不存第二份副本；未命中落缓存前先把书 rememberMany 进书库，
保证命中时 id 都拼得回。存储复用 http 缓存表（Cache.fetch 任意键）。

@module koplugin.book.source.store_cache
--]]

local Cache = require("http.cache")
local BookDB = require("book.books_db")
local BookStore = require("book.store")
local JSON = require("json")

local StoreCache = {}

-- 书城书单的保鲜期，全插件一份：榜单不是行情，十分钟内的重问直接回缓存。
local TTL = 10 * 60

---@param kind string browse / search
---@param source_id string
---@param arg string 节点 id 或搜索关键词
---@return string
local function key(kind, source_id, arg)
    return "store\0" .. kind .. "\0" .. source_id .. "\0" .. arg
end

--- 结果落缓存的形状：只记 id 顺序与 groups，书本体不进缓存。
---@param res { data: Book[], groups: table[]|nil }
---@return string
local function encode(res)
    local ids = {}
    for _idx, book in ipairs(res.data or {}) do ids[#ids + 1] = book.stable_id end
    return JSON.encode({ ids = ids, groups = res.groups })
end

--- 命中后按 id 顺序从书库拼回 Book[]；已删 / 不在库的跳过。
---@param source_id string
---@param raw string
---@return { data: Book[], groups: table[]|nil }|nil
local function decode(source_id, raw)
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.ids) ~= "table" then return nil end
    local rows = BookDB.getMany(source_id, data.ids)
    local books = {}
    for _idx, id in ipairs(data.ids) do
        local book = rows[id]
        if book then books[#books + 1] = book end
    end
    return { data = books, groups = data.groups }
end

--- 读穿一条书城数据：命中回缓存；未命中调 load（与源 browse/search 同形的回调）拉取并写回，失败不写。
---@param cache_key string
---@param source_id string
---@param load fun(cb: fun(res: table|nil, err: string|nil)): { cancel: fun() }|nil
---@param cb fun(res: { data: Book[], groups: table[]|nil }|nil, err: string|nil)
---@return { cancel: fun() }
local function through(cache_key, source_id, load, cb)
    return Cache.fetch(cache_key, TTL, function(done)
        return load(function(res, err)
            if not res then
                done(nil, err)
                return
            end
            BookStore.rememberMany(res.data or {})
            done(encode(res))
        end)
    end, function(raw, err)
        if raw == nil then
            cb(nil, err)
            return
        end
        local res = decode(source_id, raw)
        if res then
            cb(res)
            return
        end
        -- 缓存值解不开（跨版本形状变了）：当未命中现拉一遍，坏行等 TTL 自行过期。
        load(cb)
    end)
end

--- 书城浏览读穿：opts 同源 browseAsync。
---@param source BookSource 带 browseAsync 的源
---@param opts { node?: string, limit?: integer }
---@param cb fun(res: { data: Book[], groups: table[] }|nil, err: string|nil)
---@return { cancel: fun() }
function StoreCache.browse(source, opts, cb)
    return through(key("browse", source.id, opts.node or ""), source.id, function(done)
        return source:browseAsync(opts, done)
    end, cb)
end

--- 书城搜索读穿。
---@param source BookSource 带 searchAsync 的源
---@param keyword string
---@param cb fun(res: { data: Book[] }|nil, err: string|nil)
---@return { cancel: fun() }
function StoreCache.search(source, keyword, cb)
    return through(key("search", source.id, keyword), source.id, function(done)
        return source:searchAsync(keyword, done)
    end, cb)
end

return StoreCache
