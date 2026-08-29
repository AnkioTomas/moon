--[[--
source.chapter：源侧目录选择、正文落盘与本地文件复用。

@module tests.source.chapter_spec
--]]

local Assert = require("support.assert")
local Config = require("support.config")
local Stubs = require("support.stubs")
local lfs = require("libs/libkoreader-lfs")
Stubs.install()
Stubs.reset()

local tmp = Config.dir() .. "/.moon/source-chapter-spec"
local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return end
    local parent = path:match("(.+)/[^/]+$")
    if parent then ensureDir(parent) end
    lfs.mkdir(path)
end
ensureDir(tmp)
for name in lfs.dir(tmp) do
    if name ~= "." and name ~= ".." then os.remove(tmp .. "/" .. name) end
end

local pending
local book_row
package.preload["utils.paths"] = function()
    return { chapterPath = function(_, idx) return tmp .. "/" .. idx .. ".html" end }
end
package.preload["utils.db.progress"] = function()
    return { get = function() return pending end }
end
package.preload["utils.db.book"] = function()
    return { get = function() return book_row end }
end
local touches = {}
local touch_error
package.preload["book.store"] = function()
    return { touchAsync = function(path, identity, opts, cb)
        touches[#touches + 1] = {
            path = path,
            identity = identity,
            chapter_idx = opts.chapter_idx,
            toc = opts.toc,
            book = opts.book,
        }
        if touch_error then cb(nil, touch_error) else cb(true) end
    end }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, fn) fn() end }
end
local progress_ui = { shown = 0 }
package.preload["ui/widget/progressbardialog"] = function()
    return { new = function()
        return {
            show = function() progress_ui.shown = (progress_ui.shown or 0) + 1 end,
            close = function() end,
            reportProgress = function() end,
        }
    end }
end
package.loaded["ui/network/manager"] = nil
package.loaded["ui/widget/progressbardialog"] = nil

package.loaded["source.chapter"] = nil
local Chapter = require("source.chapter")
local identity = { source_id = "test", stable_id = "book" }
local toc = {
    { idx = 1, title = "一" },
    { idx = 2, title = "二" },
    { idx = 3, title = "三" },
}
local fetched = {}
local ops = {
    loadToc = function(_, cb) cb(toc) end,
    fetchContent = function(_, item, cb)
        fetched[#fetched + 1] = item.idx
        cb({ title = item.title, text = "正文" .. item.idx })
    end,
}

local path
Chapter.openAsync({ type = "chapter" }, identity, { title = "书" }, { chapter_idx = 2 }, ops, function(p)
    path = p
end)
Assert.eq(fetched[1], 2)
Assert.eq(touches[1].path, path)
Assert.eq(touches[1].chapter_idx, 2)
Assert.len(touches[1].toc, 3)
Assert.eq(touches[1].book.title, "书")
local f = assert(io.open(path, "rb"))
local html = f:read("*a")
f:close()
Assert.is_true(html:find("<h1>二</h1>", 1, true) ~= nil)
Assert.is_true(html:find("<p>正文2</p>", 1, true) ~= nil)

-- 已落盘且无远程 img 时直接复用，不再请求正文。
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p) path = p end)
Assert.len(fetched, 1)

-- 缓存 HTML 仍含远程 img 时必须重新拉取并内联。
local stale = io.open(tmp .. "/2.html", "wb")
stale:write('<!DOCTYPE html><html><body><img src="https://res.weread.qq.com/wrepub/x.png"/></body></html>')
stale:close()
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p) path = p end)
Assert.eq(fetched[#fetched], 2)
Assert.len(fetched, 2)

-- 未指定章时优先使用本地 pending_progress。
pending = { chapter_idx = 3 }
Chapter.openAsync({ type = "chapter" }, identity, {}, nil, ops, function(p) path = p end)
Assert.eq(touches[#touches].chapter_idx, 3)
Assert.eq(fetched[#fetched], 3)

-- 书籍记录可能存在但尚未登记 path；缓存检查必须把 nil 当作未命中，不能传给 lfs。
book_row = { path = nil }
local nil_path_err
Chapter.openAsync({ type = "chapter" }, identity, {}, nil, ops, function(_, err) nil_path_err = err end)
Assert.is_nil(nil_path_err)
book_row = nil

-- 数据库登记失败时不能交付物理路径。
touch_error = "db failed"
local failed_path, failed_err
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 1 }, ops, function(p, e)
    failed_path, failed_err = p, e
end)
Assert.is_nil(failed_path)
Assert.eq(failed_err, "db failed")

-- 新内容写入失败不能删除已有缓存，也不能把半截文件交给阅读器。
local old_html = '<!DOCTYPE html><html><body><img src="https://example.com/old.png"/></body></html>'
local old = assert(io.open(tmp .. "/1.html", "wb"))
old:write(old_html)
old:close()
local real_open = io.open
io.open = function(file, mode)
    if file == tmp .. "/1.html.part" and mode == "wb" then
        return {
            write = function() return nil, "disk full" end,
            close = function() return true end,
        }
    end
    return real_open(file, mode)
end
local write_failed_path, write_failed_err
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 1 }, ops, function(p, err)
    write_failed_path, write_failed_err = p, err
end)
io.open = real_open
Assert.is_nil(write_failed_path)
Assert.eq(write_failed_err, "disk full")
local preserved = assert(io.open(tmp .. "/1.html", "rb"))
Assert.eq(preserved:read("*a"), old_html)
preserved:close()

-- cancel 必须传给当前源任务，迟到回调不能继续下载正文。
local load_callback
local cancelled = 0
local fetched_after_cancel = 0
local cancelled_job = Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 1 }, {
    loadToc = function(_, cb)
        load_callback = cb
        return { cancel = function() cancelled = cancelled + 1 end }
    end,
    fetchContent = function()
        fetched_after_cancel = fetched_after_cancel + 1
    end,
}, function() end)
cancelled_job.cancel()
Assert.eq(cancelled, 1)
load_callback(toc)
Assert.eq(fetched_after_cancel, 0)

-- UI 源契约：最终回调始终异步，取消后不再交付结果。
touch_error = nil
os.remove(tmp .. "/2.html")
local ui_path
local ui_job = Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops,
    function(p) ui_path = p end)
Assert.is_nil(ui_path)
Stubs.flush()
Assert.not_nil(ui_path)
Assert.eq(progress_ui.shown, 1)
ui_path = nil
progress_ui.shown = 0
ui_job = Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops,
    function(p) ui_path = p end)
ui_job.cancel()
Stubs.flush()
Assert.is_nil(ui_path)

-- 本地章节已存在时快开，不弹准备框，也不启动重复的后台打开流水线。
local fast_path
local touch_before = #touches
Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p)
    fast_path = p
end)
Stubs.flush()
Assert.eq(fast_path, tmp .. "/2.html")
Assert.eq(progress_ui.shown, 0)
Stubs.flush()
Assert.eq(#touches, touch_before)

-- 预取：已有文件跳过，只拉取缺失章。
os.remove(tmp .. "/2.html")
os.remove(tmp .. "/3.html")
local prefetched = {}
local prefetch_ops = {
    fetchContent = function(_, item, cb)
        prefetched[#prefetched + 1] = item.idx
        cb({ title = item.title, text = "预取" .. item.idx })
    end,
}
Chapter.prefetchAsync(identity, { title = "书" }, toc, 1, 3, prefetch_ops, function() end)
Stubs.flush()
Assert.eq(prefetched[1], 2)
Assert.eq(prefetched[2], 3)
Assert.len(prefetched, 2, "共 3 章时从第 1 章只预取 2、3")
Assert.is_true(io.open(tmp .. "/2.html", "rb") ~= nil)

-- 单章返回 HTTP 425 等错误时继续后续章节，并准确回报成功/失败数量。
for i = 1, 3 do os.remove(tmp .. "/" .. i .. ".html") end
local cached, total, failed, last_error
Chapter.prefetchAsync(identity, { title = "书" }, toc, 0, 3, {
    fetchContent = function(_, item, cb)
        if item.idx == 2 then
            cb(nil, "HTTP 425")
        else
            cb({ title = item.title, text = "正文" .. item.idx })
        end
    end,
}, function(done, all, bad, err)
    cached, total, failed, last_error = done, all, bad, err
end)
Stubs.flush()
Assert.eq(cached, 2)
Assert.eq(total, 3)
Assert.eq(failed, 1)
Assert.eq(last_error, "HTTP 425")

for name in lfs.dir(tmp) do
    if name ~= "." and name ~= ".." then os.remove(tmp .. "/" .. name) end
end
lfs.rmdir(tmp)
for _, name in ipairs({
    "utils.paths", "utils.db.progress", "utils.db.book", "book.store", "source.chapter",
    "ui/network/manager", "ui/widget/progressbardialog",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
