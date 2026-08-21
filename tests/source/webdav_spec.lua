--[[--
source.webdav 门面离线用例：整本下载、校验、缓存与落库由源自己完成。

@module tests.source.webdav_spec
--]]

local Assert = require("support.assert")
local lfs = require("libs/libkoreader-lfs")
local open_dir = os.tmpname() .. ".webdav-open"
os.remove(open_dir)
assert(lfs.mkdir(open_dir))

local rec = {}
local client = {}

package.preload["source.base"] = function() return {} end
package.preload["utils.settings"] = function()
    return { getSource = function() return {} end }
end
package.preload["source.webdav.client"] = function()
    return { new = function() return client end }
end
package.preload["utils.paths"] = function()
    return {
        ensureBookWork = function() end,
        bookWorkDir = function() return open_dir end,
    }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function()
            return {
                show = function() end,
                close = function() rec.dialog_closed = true end,
                reportProgress = function(_, bytes) rec.progress = bytes end,
            }
        end,
    }
end
package.preload["book.store"] = function()
    return {
        touchAsync = function(path, identity, _, cb)
            rec.touch_path = path
            rec.touch_identity = identity
            cb(true)
        end,
        reconcileAsync = function(source_id, books, _, cb)
            rec.reconciled_source = source_id
            rec.reconciled_books = books
            cb({ pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false })
            return { cancel = function() end }
        end,
    }
end

function client:downloadAsync(stable_id, path, on_progress, cb)
    rec.download_count = (rec.download_count or 0) + 1
    rec.download_id = stable_id
    rec.download_path = path
    local file = assert(io.open(path, "wb"))
    file:write(rec.body or "%PDF-1.7")
    file:close()
    if on_progress then on_progress(8) end
    cb(rec.ok ~= false, rec.err)
    return { cancel = function() end }
end

function client:listAsync(path, cb)
    rec.listed = rec.listed or {}
    rec.listed[#rec.listed + 1] = path
    cb(assert(rec.tree[path]))
    return { cancel = function() end }
end

local source = require("source.webdav").new()
Assert.eq(type(source.openBookAsync), "function")
Assert.is_nil(source.materializeWholeAsync)

local path = open_dir .. "/book.pdf"
local identity = {
    source_id = "webdav",
    stable_id = "shelf/manual.pdf",
    book = { title = "Manual", size = 8 },
}
local opened, open_err
source:openBookAsync(identity, nil, function(p, err) opened, open_err = p, err end)
Assert.eq(rec.download_count, 1)
Assert.eq(rec.download_id, identity.stable_id)
Assert.eq(rec.download_path, path .. ".part")
Assert.eq(rec.progress, 8)
Assert.is_true(rec.dialog_closed)
Assert.eq(opened, path)
Assert.is_nil(open_err)
Assert.eq(rec.touch_path, path)
Assert.eq(rec.touch_identity, identity)

rec.download_count = nil
opened = nil
source:openBookAsync(identity, nil, function(p) opened = p end)
Assert.is_nil(rec.download_count)
Assert.eq(opened, path)

os.remove(path)
rec.body = "<html>challenge</html>"
source:openBookAsync(identity, nil, function(p, err) opened, open_err = p, err end)
Assert.is_nil(opened)
Assert.eq(open_err, "下载文件校验失败")
Assert.is_nil(lfs.attributes(path .. ".part"))

-- 完整递归目录成功后只对账一次；前两级目录映射 category / series。
rec.tree = {
    [""] = {
        { is_dir = true, name = "fiction", path = "fiction" },
        { is_dir = false, name = "root.pdf", path = "root.pdf" },
    },
    ["fiction"] = {
        { is_dir = true, name = "trilogy", path = "fiction/trilogy" },
        { is_dir = false, name = "one.epub", path = "fiction/one.epub" },
    },
    ["fiction/trilogy"] = {
        { is_dir = false, name = "two.epub", path = "fiction/trilogy/two.epub" },
    },
}
local sync_result
source:syncBooksAsync(nil, function(result) sync_result = result end)
Assert.eq(table.concat(rec.listed, ","), ",fiction,fiction/trilogy")
Assert.eq(rec.reconciled_source, "webdav")
Assert.eq(#rec.reconciled_books, 3)
local by_id = {}
for _, book in ipairs(rec.reconciled_books) do by_id[book.stable_id] = book end
Assert.is_nil(by_id["root.pdf"].category)
Assert.eq(by_id["fiction/one.epub"].category, "fiction")
Assert.is_nil(by_id["fiction/one.epub"].series)
Assert.eq(by_id["fiction/trilogy/two.epub"].category, "fiction")
Assert.eq(by_id["fiction/trilogy/two.epub"].series, "trilogy")
Assert.eq(sync_result.pulled, 3)

for _, name in ipairs({
    "source.base",
    "utils.settings",
    "source.webdav.client",
    "source.webdav.mapper",
    "utils.paths",
    "ui/network/manager",
    "ui/widget/progressbardialog",
    "book.store",
    "source.webdav",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
os.remove(path)
os.remove(path .. ".part")
lfs.rmdir(open_dir)
