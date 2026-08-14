--[[--
book.store BookRef 身份离线用例

@module tests.book.store_spec
--]]

local Assert = require("support.assert")
local Contract = require("source.contract")

-- stub db / paths / lfs 最小集
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function() return nil end,
        mkdir = function() return true end,
        dir = function() return function() end end,
    }
end

local Paths = require("utils.paths")
local orig_sanitize = Paths.sanitizeSourceId
local orig_ensure = Paths.ensureBookWork
local orig_work = Paths.bookWorkDir
Paths.ensureBookWork = function() end
Paths.bookWorkDir = function(key, id)
    return "/tmp/" .. tostring(id) .. "/" .. tostring(key)
end

package.loaded["book.store"] = nil
package.loaded["utils.db"] = nil
package.preload["utils.db"] = function()
    return {
        open = function() return true end,
        getBook = function() return nil end,
        upsertBook = function() return true end,
        putToc = function() return true end,
        getToc = function() return nil end,
        upsertOpen = function() return true end,
        getOpen = function() return nil end,
        setBookMd5 = function() end,
        setBookMd5ByKey = function() end,
        md5Map = function() return {} end,
        filenameByMd5 = function() return nil end,
    }
end

local Store = require("book.store")

do
    local ref = Contract.makeRef("moon", "a.epub")
    local book = { ref = ref, title = "t", percent = 1 }
    Assert.eq(Store.refOf(book).book_key, ref.book_key)
    local key, sid, source = Store.keyForBook(book)
    Assert.eq(key, ref.book_key)
    Assert.eq(sid, "a.epub")
    Assert.eq(source, "moon")
end

do
    Assert.is_nil(Store.refOf({ id = "legacy" }))
    Assert.is_nil(Store.bookKey(nil, "a"))
    Assert.is_nil(Store.bookKey("moon", nil))
end

do
    local a = Store.bookKey("moon", "same")
    local b = Store.bookKey("wechat", "same")
    Assert.is_true(a ~= b)
end

Paths.sanitizeSourceId = orig_sanitize
Paths.ensureBookWork = orig_ensure
Paths.bookWorkDir = orig_work
package.preload["utils.db"] = nil
package.loaded["utils.db"] = nil
package.loaded["book.store"] = nil
package.preload["libs/libkoreader-lfs"] = nil
package.loaded["libs/libkoreader-lfs"] = nil
