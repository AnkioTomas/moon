--[[--
豆瓣文字格式升级：联网刷新旧的可读标记，离线继续使用旧目录。

@module tests.source.douban.toc_cache_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
package.preload["json"] = function() return require("support.json_stub") end
local Mapper = require("source.douban.mapper")
local connected, calls, saved = false, 0, 0
local old = { { uid = "1", toc_version = Mapper.TOC_VERSION - 1, vip = true } }
local fresh = { { uid = "1", toc_version = Mapper.TOC_VERSION, vip = false } }
local cached = old
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end }
end
package.preload["source.douban.client"] = function()
    return {
        load = function() end,
        tocAsync = function(_id, cb)
            calls = calls + 1
            cb(fresh)
            return { cancel = function() end }
        end,
    }
end
package.preload["source.toc"] = function()
    return {
        read = function() return cached end,
        put = function(_source, _id, toc)
            saved = saved + 1
            cached = toc
            return true
        end,
    }
end
local source = require("source.douban").new()
local identity = { source_id = "douban", stable_id = "test" }
local result
source:loadTocAsync(identity, function(toc) result = toc end)
Stubs.flush()
Assert.eq(result, old)
Assert.eq(calls, 0)
Assert.eq(saved, 0)

connected = true
source:loadTocAsync(identity, function(toc) result = toc end)
Assert.eq(result, fresh)
Assert.eq(result[1].vip, false)
Assert.eq(calls, 1)
Assert.eq(saved, 1)
