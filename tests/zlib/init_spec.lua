--[[-- 全局 Z-Library 书城分页与导入编排用例。 @module tests.zlib.init_spec --]]

local Assert = require("support.assert")

local original_preload = {}
for _, name in ipairs({ "zlib.client", "utils.settings", "utils.paths" }) do
    original_preload[name] = package.preload[name]
end
local fake = {}
function fake:listPopularAsync(cb)
    cb({ success = 1, books = {
        { id = 1, hash = "a", title = "A" },
        { id = 2, hash = "b", title = "B" },
        { id = 3, hash = "c", title = "C" },
    } })
    return { cancel = function() end }
end
function fake:searchAsync(query, page, size, cb)
    fake.search = { query, page, size }
    cb({ books = { { id = 9, hash = "z", title = "Z" } }, pagination = { total_items = 7 } })
    return { cancel = function() end }
end
function fake:detailAsync(id, hash, cb)
    fake.detail = { id, hash }
    cb({ id = id, hash = hash, title = "下载书", author = "作者", extension = "epub" })
    return { cancel = function() end }
end
function fake:downloadAsync(id, hash, path, _, cb)
    fake.download = { id, hash, path }
    cb(true)
    return { cancel = function() end }
end

package.preload["zlib.client"] = function()
    return { new = function() return fake end }
end
package.preload["utils.settings"] = function()
    return { getSource = function() return {} end }
end
package.preload["utils.paths"] = function()
    return {
        ensureBookWork = function() end,
        bookWorkDir = function() return "/tmp/zlib-test" end,
    }
end
package.loaded["zlib.client"] = nil
package.loaded["utils.settings"] = nil
package.loaded["utils.paths"] = nil
package.loaded["zlib.init"] = nil

local Zlib = require("zlib.init")
local result
Zlib:listStoreAsync({ page = 2, page_size = 2 }, function(v) result = v end)
Assert.eq(result.count, 3)
Assert.len(result.data, 1)
Assert.eq(result.data[1].title, "C")

Zlib:listStoreAsync({ search = "lua", page = 3, page_size = 8 }, function(v) result = v end)
Assert.eq(fake.search[1], "lua")
Assert.eq(fake.search[2], 3)
Assert.eq(fake.search[3], 8)
Assert.eq(result.count, 7)

local imported
local source = {
    importBookAsync = function(_, path, filename, cb)
        imported = { path, filename }
        cb(true)
        return { cancel = function() end }
    end,
}
local installed
Zlib.installAsync(source, {
    ref = { source_id = "zlib", stable_id = "10:hash10" },
    title = "列表书",
}, nil, function(ok, err, filename)
    installed = { ok, err, filename }
end)
Assert.eq(fake.detail[1], "10")
Assert.eq(fake.download[2], "hash10")
Assert.eq(imported[2], "下载书 - 作者.epub")
Assert.is_true(installed[1])
Assert.eq(installed[3], "下载书 - 作者.epub")

for _, name in ipairs({ "zlib.client", "utils.settings", "utils.paths" }) do
    package.preload[name] = original_preload[name]
    package.loaded[name] = nil
end
package.loaded["zlib.init"] = nil
