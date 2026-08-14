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
package.loaded["utils.db.base"] = nil
package.loaded["utils.db.book"] = nil
package.loaded["utils.db.toc"] = nil
package.loaded["utils.db.open"] = nil
package.preload["utils.db.base"] = function()
    return { open = function() return true end }
end
package.preload["utils.db.book"] = function()
    return {
        get = function() return nil end,
        upsert = function() return true end,
        setMd5 = function() end,
        setMd5ByKey = function() end,
        md5Map = function() return {} end,
        expireBefore = function() end,
        stripMeta = function() end,
    }
end
package.preload["utils.db.toc"] = function()
    return {
        put = function() return true end,
        get = function() return nil end,
        delete = function() end,
        deleteExpired = function() end,
        clear = function() end,
    }
end
package.preload["utils.db.open"] = function()
    return {
        upsert = function() return true end,
        get = function() return nil end,
        all = function() return {} end,
        delete = function() end,
        clear = function() end,
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

do
    Assert.eq(Store.bookFilePath("key", "webdav", "books/a.pdf"), "/tmp/webdav/key/book.pdf")
    Assert.eq(Store.bookFilePath("key", "webdav", "books/a.unknown"), "/tmp/webdav/key/book.epub")
end

Paths.sanitizeSourceId = orig_sanitize
Paths.ensureBookWork = orig_ensure
Paths.bookWorkDir = orig_work
for _, k in ipairs({
    "utils.db.base",
    "utils.db.book",
    "utils.db.toc",
    "utils.db.open",
    "book.store",
    "libs/libkoreader-lfs",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
