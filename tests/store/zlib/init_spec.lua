---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

--[[-- 全局 Z-Library 书城分页与导入编排用例。 @module tests.store.zlib.init_spec --]]

local Assert = require("support.assert")

local original_preload = {}
for _, name in ipairs({ "store.zlib.client", "utils.settings", "utils.paths" }) do
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
function fake:searchAsync(query, page, size, cb, language, filters)
    fake.search = { query, page, size, language, filters }
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
    if fake.defer_download then
        fake.download_cb = cb
    else
        cb(true)
    end
    return { cancel = function() fake.download_cancelled = true end }
end

package.preload["store.zlib.client"] = function()
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
package.loaded["store.zlib.client"] = nil
package.loaded["utils.settings"] = nil
package.loaded["utils.paths"] = nil
package.loaded["store.zlib"] = nil

local Zlib = require("store.zlib")
local result
local GetText = require("gettext")
local original_lang = GetText.current_lang
GetText.current_lang = "zh_CN"
Zlib:listStoreAsync({ page = 2, page_size = 2 }, function(v) result = v end)
Assert.eq(fake.search[1], "")
Assert.eq(fake.search[2], 2)
Assert.eq(fake.search[3], 2)
Assert.eq(fake.search[4], "chinese")
Assert.eq(result.count, 7)
Assert.len(result.data, 1)
Assert.eq(result.data[1].title, "Z")

-- 浏览：节点三段（排序:语言:格式）翻成搜索过滤；chip 只换自己那一位，"-" 表示不限。
do
    local res
    Zlib:browseAsync({ node = "date:chinese:epub", limit = 1 }, function(v) res = v end)
    Assert.eq(fake.search[1], "")
    Assert.eq(fake.search[4], "chinese")
    Assert.eq(fake.search[5].order, "date")
    Assert.eq(fake.search[5].extension, "epub")
    Assert.len(res.data, 1)
    Assert.len(res.groups, 3)
    Assert.eq(res.groups[1].active, "date:chinese:epub")
    Assert.eq(res.groups[3].chips[1].id, "date:chinese:-")
    Zlib:browseAsync({ node = "popular:-:-", limit = 1 }, function(v) res = v end)
    Assert.is_nil(fake.search[4])
    Assert.is_nil(fake.search[5].extension)
end

Zlib:listStoreAsync({ search = "lua", page = 3, page_size = 8 }, function(v) result = v end)
Assert.eq(fake.search[1], "lua")
Assert.eq(fake.search[2], 3)
Assert.eq(fake.search[3], 8)
Assert.is_nil(fake.search[4])
Assert.eq(result.count, 7)

GetText.current_lang = "zh_TW"
Zlib:listStoreAsync({}, function(v) result = v end)
Assert.eq(fake.search[4], "traditional chinese")

GetText.current_lang = "xx"
Zlib:listStoreAsync({ page = 2, page_size = 2 }, function(v) result = v end)
Assert.eq(result.count, 3)
Assert.len(result.data, 1)
Assert.eq(result.data[1].title, "C")
GetText.current_lang = original_lang

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
    source_id = "zlib",
    stable_id = "10:hash10",
    title = "列表书",
}, nil, function(ok, err, filename)
    installed = { ok, err, filename }
end)
Assert.eq(fake.detail[1], "10")
Assert.eq(fake.download[2], "hash10")
Assert.eq(imported[2], "下载书 - 作者.epub")
Assert.is_true(installed[1])
Assert.eq(installed[3], "下载书 - 作者.epub")

-- 文件名超长：书名加作者超限去掉作者，书名本身超限按字符边界截断。
local function installName(title, authors)
    Zlib.installAsync(source, { source_id = "zlib", stable_id = "12:hash12", title = title,
        authors = authors, format = "epub" }, nil, function() end)
    return imported[2]
end
Assert.eq(installName(("书"):rep(60), ("作"):rep(20)), ("书"):rep(60) .. ".epub")
Assert.eq(installName(("书"):rep(100), "作者"), ("书"):rep(66) .. ".epub")
Assert.eq(installName(("书"):rep(100), nil), ("书"):rep(66) .. ".epub")
Assert.eq(installName(("书"):rep(30), ("作"):rep(10)), ("书"):rep(30) .. " - " .. ("作"):rep(10) .. ".epub")

-- 取消发生在导入阶段时，必须取消导入任务并删除下载临时文件。
local original_remove = os.remove
local removed
os.remove = function(path)
    removed = path
    return true
end
fake.defer_download = true
local import_cancelled = false
local pending_source = {
    importBookAsync = function()
        return { cancel = function() import_cancelled = true end }
    end,
}
local install_job = Zlib.installAsync(pending_source, {
    source_id = "zlib",
    stable_id = "11:hash11",
    title = "待取消",
    format = "epub",
}, nil, function() end)
fake.download_cb(true)
install_job.cancel()
Assert.is_true(import_cancelled)
Assert.eq(removed, fake.download[3])
Assert.matches(removed, "/待取消%.epub$")
os.remove = original_remove

for _, name in ipairs({ "store.zlib.client", "utils.settings", "utils.paths" }) do
    package.preload[name] = original_preload[name]
    package.loaded[name] = nil
end
package.loaded["store.zlib"] = nil
