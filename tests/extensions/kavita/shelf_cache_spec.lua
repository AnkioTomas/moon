--[[--
Kavita 源的书架缓存钩子：shelf_cache 能力、shelfCache 同步返回投影、
syncBooksAsync 同步后预热（05 A1）、coverRequest 优先本地封面（05 A8）。

不复用 source_spec 的整套书架夹具：这里只碰钩子本身，HTTP / 书库 / 目录都最小打桩。

@module tests.extensions.kavita.shelf_cache_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, inject-field

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
Stubs.install()

local PLUGIN = Config.root() .. "/extensions/moonsource-kavita.koplugin"
-- 走 preload 不改 package.path：插件根上的 main.lua 会顶掉月读的 main。
for _idx, name in ipairs({ "client", "position", "annotation", "source", "cache", "volume_list", "stats" }) do
    package.preload["moonsource_kavita." .. name] = function()
        return dofile(PLUGIN .. "/moonsource_kavita/" .. name .. ".lua")
    end
end

-- 往返桩：encode 登记表并发令牌，decode 凭令牌取回（不是令牌就报错，同真解析器）。
local encoded = {}
package.preload["json"] = function()
    return {
        encode = function(value)
            encoded[#encoded + 1] = value
            return "\0json" .. #encoded
        end,
        decode = function(text)
            return encoded[tonumber(text:match("^%z?json(%d+)$"))] or error("not json: " .. text)
        end,
    }
end

local cfg = { base_url = "http://kav/", api_key = "k", libraries = { ["1"] = true } }
package.preload["utils.settings"] = function()
    return {
        get = function() return { active_source = "local" } end,
        save = function() end,
        getSource = function() return cfg end,
        saveSource = function() end,
    }
end

-- HTTP：只有书架快照这一个路由。
local routes, requested = {}, {}
package.preload["http.request"] = function()
    return {
        ok = function(code)
            code = tonumber(code)
            return code ~= nil and code >= 200 and code < 300
        end,
        header = function() end,
        request = function(opts, cb)
            requested[#requested + 1] = opts
            local route = routes[opts.method .. " " .. opts.url:match("^http://kav(/[^?]*)")]
            require("ui/uimanager"):nextTick(function()
                cb(route and route(opts) or { code = 404, body = "" })
            end)
            return { cancel = function() end }
        end,
    }
end

-- 本地库：钩子只需要「取一本书」与「已同步身份」。
local books = {}
package.loaded["book.books_db"] = {
    get = function(_source_id, stable_id) return books[stable_id] end,
    libraryStableIdsBySource = function() return {} end,
}
package.loaded["book.progress_db"] = {
    get = function() return nil end,
}
package.loaded["book.store"] = { rememberMany = function() end }

local sequence = {}
package.loaded["source.shelf"] = {
    reconcile = function(_source_id, list)
        sequence[#sequence + 1] = "reconcile"
        return { pulled = #list, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
    end,
}

local SourceMod = require("moonsource_kavita.source")
local Cache = require("moonsource_kavita.cache")
local source = SourceMod.new()

-- 能力：声明 shelf_cache，UI 据此决定断网时是否收窄书架（05 A2）。
local caps = source:capabilities()
Assert.is_true(caps.shelf_cache, "Kavita 声明书架缓存能力")
Assert.is_true(caps.stats_pull, "原有能力不受影响")

-- shelfCache：同步返回适配层记忆的投影；未配置不触盘。
local projection = { series_ids = { ["700"] = true }, mark = { ["700"] = true }, cover = {} }
local shelf_calls = 0
local real_shelf = Cache.shelf
Cache.shelf = function()
    shelf_calls = shelf_calls + 1
    return projection
end
Assert.eq(source:shelfCache(), projection, "shelfCache 原样交回适配层投影")
Assert.eq(shelf_calls, 1)
cfg.base_url = ""
Assert.is_nil(SourceMod.new():shelfCache(), "未配置返回 nil")
Assert.eq(shelf_calls, 1, "未配置不读投影")
cfg.base_url = "http://kav/"

-- coverRequest：投影里有本地封面且文件存在 → 本地路径，不再走鉴权 URL（05 A8）。
local cover_path = Config.dir() .. "/shelf_cover_700.jpg"
local file = assert(io.open(cover_path, "wb"))
file:write("jpg")
file:close()
Cache.shelf = function() return { series_ids = {}, mark = {}, cover = { ["700"] = cover_path } } end
local req = select(1, source:coverRequest({ source_id = "ext.kavita", stable_id = "700" }))
Assert.eq(req.url, cover_path, "已缓存系列用本地封面")
Assert.is_nil(req.headers, "本地文件不需要鉴权头")
-- 投影给了路径但文件没了 / 卷身份没有整系列封面 → 维持在线 URL。
Cache.shelf = function() return { series_ids = {}, mark = {}, cover = { ["700"] = cover_path .. ".gone" } } end
req = select(1, source:coverRequest({ source_id = "ext.kavita", stable_id = "700" }))
Assert.is_true(req.url:find("series-cover", 1, true) ~= nil, "文件不存在退回在线封面")
Assert.not_nil(req.headers)
req = select(1, source:coverRequest({ source_id = "ext.kavita", stable_id = "700:7001" }))
Assert.is_true(req.url:find("chapter-cover", 1, true) ~= nil, "卷身份没有系列封面时走章封面")
-- 适配层没给投影（无 index）：照旧在线封面。
Cache.shelf = function() return nil end
req = select(1, source:coverRequest({ source_id = "ext.kavita", stable_id = "700" }))
Assert.is_true(req.url:find("series-cover", 1, true) ~= nil)
Cache.shelf = real_shelf

-- syncBooksAsync 预热：对账后、回调前把投影建好，进书架时 O(1)（05 A1）。
sequence, requested = {}, {}
Cache.shelf = function()
    sequence[#sequence + 1] = "shelf"
    return projection
end
routes["POST /api/Series/all-v2"] = function()
    return { code = 200, body = require("json").encode({
        { id = 700, name = "漫画一", libraryName = "漫画", wordCount = 10 },
    }) }
end
source.backfillMeta = function() end
local synced
source:syncBooksAsync(nil, function(result, err)
    sequence[#sequence + 1] = "cb"
    synced = { result = result, err = err }
end)
Stubs.flush()
Assert.not_nil(synced)
Assert.is_nil(synced.err)
Assert.eq(synced.result.pulled, 1, "对账结果照旧回调")
Assert.eq(table.concat(sequence, ","), "reconcile,shelf,cb", "预热排在回调之前")

-- 预热失败不拖垮同步：投影只是书架标记，缓存模块异常照样要回调对账结果。
sequence, requested = {}, {}
local broken_sequence = sequence
Cache.shelf = function()
    broken_sequence[#broken_sequence + 1] = "shelf"
    error("kamare index broken")
end
local second
source:syncBooksAsync(nil, function(result, err) second = { result = result, err = err } end)
Stubs.flush()
Assert.not_nil(second and second.result, "预热异常不影响同步结果")
Assert.eq(table.concat(sequence, ","), "reconcile,shelf")
Cache.shelf = real_shelf

-- Registry.reload() 会重建源实例：新实例顺手丢掉旧服务器的投影（05 A1 的第三类失效点）。
local resets = 0
local real_reset = Cache.resetShelf
Cache.resetShelf = function()
    resets = resets + 1
    return real_reset()
end
SourceMod.new()
Assert.eq(resets, 1, "重建源实例即失效书架投影")
Cache.resetShelf = real_reset

return true
