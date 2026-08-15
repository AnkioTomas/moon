--[[--
book.store BookRef 身份离线用例

@module tests.book.store_spec
--]]

local Assert = require("support.assert")
local BookRef = require("types.book").BookRef

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
Paths.bookWorkDir = function(stable_id, id)
    return "/tmp/" .. tostring(id) .. "/" .. tostring(stable_id)
end

package.loaded["book.store"] = nil
package.loaded["utils.db.base"] = nil
package.loaded["utils.db.book"] = nil
package.loaded["utils.db.open"] = nil
package.preload["utils.db.base"] = function()
    return { open = function() return true end }
end
package.preload["utils.db.book"] = function()
    return {
        get = function() return nil end,
        upsert = function() return true end,
        expireBefore = function() end,
        stripMeta = function() end,
    }
end
package.preload["utils.db.open"] = function()
    return {
        upsert = function() return true end,
        get = function() return nil end,
        getByPath = function() return nil end,
        all = function() return {} end,
        delete = function() end,
        clear = function() end,
    }
end
package.preload["utils.db.queue"] = function()
    return {
        run = function(worker, opts) end,
        clear = function() end,
    }
end

local Store = require("book.store")

do
    local ref = BookRef.new("moon", "a.epub")
    local book = { ref = ref, title = "t", percent = 1 }
    local got = Store.refOf(book)
    Assert.eq(got.source_id, ref.source_id)
    Assert.eq(got.stable_id, ref.stable_id)
end

do
    Assert.is_nil(Store.refOf({ id = "legacy" }))
end

do
    Assert.eq(Store.bookFilePath("books/a.pdf", "webdav"), "/tmp/webdav/books/a.pdf/book.pdf")
    Assert.eq(Store.bookFilePath("books/a.unknown", "webdav"), "/tmp/webdav/books/a.unknown/book.epub")
end

Paths.sanitizeSourceId = orig_sanitize
Paths.ensureBookWork = orig_ensure
Paths.bookWorkDir = orig_work
for _, k in ipairs({
    "utils.db.base",
    "utils.db.book",
    "utils.db.open",
    "utils.db.queue",
    "book.store",
    "libs/libkoreader-lfs",
}) do
    package.preload[k] = nil
    package.loaded[k] = nil
end
