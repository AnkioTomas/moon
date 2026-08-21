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
function fake:searchAsync(query, page, size, cb, language)
    fake.search = { query, page, size, language }
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
Assert.matches(removed, "%.part$")
os.remove = original_remove

for _, name in ipairs({ "zlib.client", "utils.settings", "utils.paths" }) do
    package.preload[name] = original_preload[name]
    package.loaded[name] = nil
end
package.loaded["zlib.init"] = nil
