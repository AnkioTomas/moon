--[[--
拷贝漫画书架同步：全量同步与 dirty_only 一样先把本地删除推上云端，再拉远端对账。

@module tests.source.copymanga.sync_spec
--]]

local Assert = require("support.assert")

local fake_client = {}
local calls = {}
local finalized = {}

local function stub(name, factory)
    package.preload[name] = factory
    package.loaded[name] = nil
end

stub("db.book", function()
    return {
        pendingDeleteIds = function() return { "gone-comic" } end,
        get = function() return nil end,
    }
end)
stub("book.store", function()
    return {
        finalizeDeleted = function(_, stable_id)
            finalized[#finalized + 1] = stable_id
            return true
        end,
        reconcile = function(_, books)
            calls[#calls + 1] = "reconcile"
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
    }
end)
stub("utils.settings", function()
    return {
        getSource = function() return { token = "tok" } end,
        saveSource = function() end,
    }
end)
stub("source.copymanga.auth", function()
    return { hasSession = function() return true end }
end)
stub("source.copymanga.client", function()
    return {
        new = function() return fake_client end,
        headers = function() return {} end,
        normalizeBaseUrl = function(url) return url end,
    }
end)

fake_client.detailAsync = function(_, stable_id, cb)
    calls[#calls + 1] = "detail:" .. stable_id
    cb({ results = { comic = { uuid = "uuid-1" } } })
    return { cancel = function() end }
end
fake_client.setCollectAsync = function(_, comic_id, on, cb)
    calls[#calls + 1] = "collect:" .. comic_id .. ":" .. tostring(on)
    cb({ code = 200 })
    return { cancel = function() end }
end
fake_client.collectAllAsync = function(_, cb)
    calls[#calls + 1] = "collectAll"
    cb({ results = { list = {} } })
    return { cancel = function() end }
end

package.loaded["source.copymanga"] = nil
local src = require("source.copymanga").new()

local result, err
src:syncBooksAsync({}, function(r, e) result, err = r, e end)
Assert.is_nil(err)
Assert.eq(calls[1], "detail:gone-comic")
Assert.eq(calls[2], "collect:uuid-1:false")
Assert.eq(calls[3], "collectAll")
Assert.eq(calls[4], "reconcile")
Assert.eq(finalized[1], "gone-comic")
Assert.eq(result.pushed, 1)
