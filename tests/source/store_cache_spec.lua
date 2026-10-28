--[[-- source.store_cache：书城数据获取层缓存读穿（命中不调源、按 id 从书库拼回、失败不写）。 @module tests.source.store_cache_spec --]]

local Assert = require("support.assert")

-- http.cache 内存假实现：只存成功值，命中原样回（TTL 语义由 http.cache 自己的用例覆盖）。
local entries = {}
package.preload["http.cache"] = function()
    return {
        fetch = function(k, _ttl, load, cb)
            local hit = entries[k]
            if hit ~= nil then
                cb(hit)
                return { cancel = function() end }
            end
            return load(function(value, err, ...)
                if value ~= nil and err == nil then entries[k] = value end
                cb(value, err, ...)
            end)
        end,
    }
end

-- 书库假实现：rememberMany 落行，getMany 按 id 取行（与真实契约同形）。
local db_rows = {}
package.preload["book.store"] = function()
    return {
        rememberMany = function(books)
            for _idx, book in ipairs(books) do db_rows[book.stable_id] = book end
        end,
    }
end
package.preload["book.books_db"] = function()
    return {
        getMany = function(_source_id, ids)
            local out = {}
            for _idx, id in ipairs(ids) do
                if db_rows[id] then out[id] = db_rows[id] end
            end
            return out
        end,
    }
end
package.preload["json"] = function()
    return {
        encode = require("support.json_stub").encode,
        decode = require("support.json_stub").decode,
    }
end
package.loaded["json"] = nil

local StoreCache = require("source.store_cache")

local calls = { browse = 0, search = 0 }
local source = {
    id = "fake",
    browseAsync = function(_, opts, cb)
        calls.browse = calls.browse + 1
        local node = opts.node or "n1"
        cb({ data = {
            { source_id = "fake", stable_id = "b2", title = "乙" },
            { source_id = "fake", stable_id = "b1", title = "甲" },
        }, groups = { { chips = { { id = node, title = "榜" } }, active = node } } })
        return { cancel = function() end }
    end,
    searchAsync = function(_, keyword, cb)
        calls.search = calls.search + 1
        if keyword == "bad" then
            cb(nil, "网络断开")
            return { cancel = function() end }
        end
        cb({ data = { { source_id = "fake", stable_id = "b1", title = "甲" } } })
        return { cancel = function() end }
    end,
}

-- 未命中：调源，结果按源顺序回（经书库解析，形状一致）。
local res
local handle = StoreCache.browse("fake", source, {}, function(r) res = r end)
Assert.eq(type(handle.cancel), "function")
Assert.eq(calls.browse, 1)
Assert.len(res.data, 2)
Assert.eq(res.data[1].stable_id, "b2")
Assert.eq(res.groups[1].active, "n1")

-- 改书库里的书名后命中：不再调源，且回的是书库最新元数据（缓存只存 id）。
db_rows.b2 = { source_id = "fake", stable_id = "b2", title = "乙·改" }
StoreCache.browse("fake", source, {}, function(r) res = r end)
Assert.eq(calls.browse, 1, "TTL 内命中不调源")
Assert.eq(res.data[1].title, "乙·改")
Assert.eq(res.groups[1].active, "n1")

-- 换节点是另一键：重新调源。
StoreCache.browse("fake", source, { node = "n2" }, function(r) res = r end)
Assert.eq(calls.browse, 2)
Assert.eq(res.groups[1].active, "n2")

-- 搜索：命中不调源；失败不写缓存，重试仍调源。
StoreCache.search("fake", source, "甲", function(r) res = r end)
Assert.eq(calls.search, 1)
Assert.eq(res.data[1].stable_id, "b1")
StoreCache.search("fake", source, "甲", function(r) res = r end)
Assert.eq(calls.search, 1, "搜索命中不调源")
StoreCache.search("fake", source, "bad", function(_r, err) res = err end)
Assert.eq(res, "网络断开")
StoreCache.search("fake", source, "bad", function(_r, err) res = err end)
Assert.eq(calls.search, 3, "失败结果不缓存")

-- 书被删后命中：拼不回的直接跳过，不报错。
db_rows.b1 = nil
StoreCache.browse("fake", source, {}, function(r) res = r end)
Assert.eq(calls.browse, 2)
Assert.len(res.data, 1)
Assert.eq(res.data[1].stable_id, "b2")

-- 缓存值解不开：当未命中现拉，返回的句柄要能取消这次现拉。
do
    local cancelled = false
    local slow = {
        browseAsync = function(_, _opts, _cb)
            return { cancel = function() cancelled = true end }
        end,
    }
    entries["store\0browse\0fake\0n3"] = "not json {"
    local h = StoreCache.browse("fake", slow, { node = "n3" }, function() end)
    h.cancel()
    Assert.is_true(cancelled, "坏缓存回落的现拉必须可取消")
end

-- 书城后端可以没有 .id：身份由调用方显式传入（对应桌面 provider.id）。
do
    local backend_calls = 0
    local backend = {
        browseAsync = function(_, _opts, cb)
            backend_calls = backend_calls + 1
            cb({ data = { { source_id = "zlib", stable_id = "z1", title = "Z" } } })
            return { cancel = function() end }
        end,
    }
    Assert.is_nil(backend.id)
    local got
    StoreCache.browse("zlib", backend, {}, function(r) got = r end)
    Assert.eq(backend_calls, 1)
    Assert.eq(got.data[1].stable_id, "z1")
    StoreCache.browse("zlib", backend, {}, function(r) got = r end)
    Assert.eq(backend_calls, 1, "显式 source_id 命中不调源")
end

-- 漏传 source_id 必须立刻报错，不能拼出 nil 键再炸。
Assert.errors(function()
    StoreCache.browse(nil, source, {}, function() end)
end, "source_id required")
