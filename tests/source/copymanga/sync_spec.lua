--[[--
拷贝漫画书架同步：复用 Shelf 的本地加删上行与远端对账。

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

stub("book.books_db", function()
    return {
        pendingDeleteIds = function() return { "gone-comic" } end,
        pendingShelfAddIds = function() return { "new-comic" } end,
        markSynced = function(_source_id, stable_id)
            calls[#calls + 1] = "synced:" .. stable_id
            return true
        end,
        get = function() return nil end,
        remove = function(_, stable_id)
            finalized[#finalized + 1] = stable_id
            return true
        end,
        reconcile = function()
            calls[#calls + 1] = "reconcile"
            return true, 0
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

fake_client.removeFromShelfAsync = function(_client, stable_id, cb)
    calls[#calls + 1] = "remove:" .. stable_id
    cb({ code = 200 })
    return { cancel = function() end }
end
fake_client.addToShelfAsync = function(_client, stable_id, cb)
    calls[#calls + 1] = "add:" .. stable_id
    cb({ code = 200 })
    return { cancel = function() end }
end
fake_client.shelfSyncAsync = function(_client, cb)
    calls[#calls + 1] = "shelf"
    cb({})
    return { cancel = function() end }
end

package.loaded["source.copymanga"] = nil
local src = require("source.copymanga").new()

local result, err
src:syncBooksAsync({}, function(r, e) result, err = r, e end)
Assert.is_nil(err)
Assert.eq(calls[1], "remove:gone-comic")
Assert.eq(calls[2], "shelf")
Assert.eq(calls[3], "add:new-comic")
Assert.eq(calls[4], "synced:new-comic")
Assert.eq(calls[5], "shelf")
Assert.eq(calls[6], "reconcile")
Assert.eq(finalized[1], "gone-comic")
Assert.eq(result.pushed, 2)

calls = {}
src:syncBooksAsync({ dirty_only = true }, function(r, e) result, err = r, e end)
Assert.is_nil(err)
Assert.eq(calls[1], "remove:gone-comic")
Assert.eq(calls[2], "add:new-comic")
Assert.eq(calls[3], "synced:new-comic")
Assert.eq(result.pushed, 2)
