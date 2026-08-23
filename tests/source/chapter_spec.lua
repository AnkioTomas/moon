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
package.preload["utils.paths"] = function()
    return { chapterPath = function(_, idx) return tmp .. "/" .. idx .. ".html" end }
end
package.preload["utils.db.progress"] = function()
    return { get = function() return pending end }
end
package.preload["utils.db.book"] = function()
    return { get = function() return nil end }
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
Chapter.openAsync({ type = "article" }, identity, { title = "书" }, { chapter_idx = 2 }, ops, function(p)
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

-- 已落盘直接复用，不再请求正文。
Chapter.openAsync({ type = "article" }, identity, {}, { chapter_idx = 2 }, ops, function(p) path = p end)
Assert.len(fetched, 1)

-- 未指定章时优先使用本地 pending_progress。
pending = { chapter_idx = 3 }
Chapter.openAsync({ type = "article" }, identity, {}, nil, ops, function(p) path = p end)
Assert.eq(touches[#touches].chapter_idx, 3)
Assert.eq(fetched[#fetched], 3)

-- 数据库登记失败时不能交付物理路径。
touch_error = "db failed"
local failed_path, failed_err
Chapter.openAsync({ type = "article" }, identity, {}, { chapter_idx = 1 }, ops, function(p, e)
    failed_path, failed_err = p, e
end)
Assert.is_nil(failed_path)
Assert.eq(failed_err, "db failed")

-- cancel 必须传给当前源任务，迟到回调不能继续下载正文。
local load_callback
local cancelled = 0
local fetched_after_cancel = 0
local cancelled_job = Chapter.openAsync({ type = "article" }, identity, {}, { chapter_idx = 1 }, {
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
local ui_job = Chapter.openWithUi({ type = "article" }, identity, {}, { chapter_idx = 2 }, ops,
    function(p) ui_path = p end)
Assert.is_nil(ui_path)
Stubs.flush()
Assert.not_nil(ui_path)
Assert.eq(progress_ui.shown, 1)
ui_path = nil
progress_ui.shown = 0
ui_job = Chapter.openWithUi({ type = "article" }, identity, {}, { chapter_idx = 2 }, ops,
    function(p) ui_path = p end)
ui_job.cancel()
Stubs.flush()
Assert.is_nil(ui_path)

-- 本地章节已存在时快开，不弹准备框，并在后台静默刷新登记。
local fast_path
local touch_before = #touches
Chapter.openWithUi({ type = "article" }, identity, {}, { chapter_idx = 2 }, ops, function(p)
    fast_path = p
end)
Stubs.flush()
Assert.eq(fast_path, tmp .. "/2.html")
Assert.eq(progress_ui.shown, 0)
Stubs.flush()
Assert.eq(#touches, touch_before + 1)

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
