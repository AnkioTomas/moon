--[[--
source.chapter：源侧目录选择、正文落盘与本地文件复用。

@module tests.source.chapter_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

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
    return {
        chapterPath = function(_, idx) return tmp .. "/" .. idx .. ".html" end,
        ensureDir = function() return true end,
    }
end
package.preload["book.progress_db"] = function()
    return { get = function() return pending end }
end
package.preload["book.books_db"] = function()
    return { get = function() return book_row end }
end
local touches = {}
local touch_error
package.preload["book.store"] = function()
    return { touch = function(path, identity, opts)
        touches[#touches + 1] = {
            path = path,
            identity = identity,
            chapter_idx = opts.chapter_idx,
            book = opts.book,
        }
        if touch_error then return false, touch_error end
        return true
    end }
end
local network = { online = true, connected = true, waited = 0 }
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return network.online end,
        isConnected = function() return network.connected end,
        runWhenOnline = function(_, fn)
            if network.online then fn() else network.waited = network.waited + 1 end
        end,
    }
end
local progress_ui = { shown = 0 }
local Themed = require("support.theme_stubs")
Themed.install()
Themed.on_show = function(o)
    if o.kind == "progress_dialog" then progress_ui.shown = progress_ui.shown + 1 end
end
package.loaded["ui/network/manager"] = nil

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
        cb({ title = item.title, html = '<p class="a">　&nbsp; 正文' .. item.idx .. '</p><pre>  代码</pre>' })
    end,
}

local path
Chapter.openAsync({ type = "chapter" }, identity, { title = "书" }, { chapter_idx = 2 }, ops, function(p)
    path = p
end)
Assert.eq(fetched[1], 2)
Assert.eq(touches[1].path, path)
Assert.eq(touches[1].chapter_idx, 2)
Assert.eq(touches[1].book.title, "书")
local f = assert(io.open(path, "rb"))
local html = f:read("*a")
f:close()
Assert.is_true(html:find("<title>书</title>", 1, true) ~= nil, "章节 HTML 的 title 必须是书名")
Assert.is_nil(html:find("<title>二</title>", 1, true))
Assert.is_nil(html:find("<h1", 1, true))
-- 段首空白 / 全角空格 / &nbsp; 剥掉（缩进归 CSS）；<pre> 不碰。
Assert.is_true(html:find('<p class="a">正文2</p>', 1, true) ~= nil)
Assert.is_true(html:find("<pre>  代码</pre>", 1, true) ~= nil)

-- 完整文档原样落盘：不套外壳、不改 title、不转段落（含百分号，不能走 string.format）。
local DOC = '<?xml version="1.0"?>\n<html><head><title></title><style>.poem{width:50%}</style></head>'
    .. '<body><h2>一</h2><p class="content">诗</p></body></html>\n'
    .. '<?xml version="1.0"?>\n<html><head><title></title></head><body><p>二</p></body></html>'
Chapter.openAsync({ type = "chapter" }, identity, { title = "书" }, { chapter_idx = 1 }, {
    loadToc = function(_, cb) cb(toc) end,
    fetchContent = function(_, item, cb)
        cb({ title = item.title, document = DOC, text = "不该用到" })
    end,
}, function(p) path = p end)
Assert.eq(assert(io.open(path, "rb")):read("*a"), DOC)

-- 已落盘且无远程 img 时直接复用，不再请求正文。
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p) path = p end)
Assert.len(fetched, 1)

-- 进程外落盘（重启后、内存判定缓存为空）的本地化 HTML 也直接复用。
local restored = io.open(tmp .. "/3.html", "wb")
restored:write('<!DOCTYPE html><html><body><img src="images/a.png"/></body></html>')
restored:close()
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 3 }, ops, function(p) path = p end)
Assert.eq(path, tmp .. "/3.html")
Assert.len(fetched, 1)

-- 旧版本落盘的纯文本试读片段不算缓存，必须重拉。
local trial = io.open(tmp .. "/3.html", "wb")
trial:write("二月春风，柳色初青。...")
trial:close()
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 3 }, ops, function(p) path = p end)
Assert.eq(fetched[#fetched], 3)
Assert.len(fetched, 2)
table.remove(fetched)
os.remove(tmp .. "/3.html")

-- 缓存 HTML 仍含远程 img 时必须重新拉取并内联。
local stale = io.open(tmp .. "/2.html", "wb")
stale:write('<!DOCTYPE html><html><body><img src="https://res.weread.qq.com/wrepub/x.png"/></body></html>')
stale:close()
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p) path = p end)
Assert.eq(fetched[#fetched], 2)
Assert.len(fetched, 2)

-- write() 留下远程 img 时不得标 ready，同进程再开仍要重拉。
local remote_n = 0
local remote_ops = {
    loadToc = function(_, cb) cb(toc) end,
    fetchContent = function(_, item, cb)
        remote_n = remote_n + 1
        cb({ title = item.title, html = '<p><img src="https://cdn/features.remote.png"/></p>' })
    end,
}
local remote_stale = io.open(tmp .. "/2.html", "wb")
remote_stale:write('<!DOCTYPE html><html><body><img src="https://cdn/stale.png"/></body></html>')
remote_stale:close()
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, remote_ops, function() end)
Assert.eq(remote_n, 1)
Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, remote_ops, function() end)
Assert.eq(remote_n, 2)

-- 未指定章时优先使用本地 pending_progress。
pending = { chapter_idx = 3 }
Chapter.openAsync({ type = "chapter" }, identity, {}, nil, ops, function(p) path = p end)
Assert.eq(touches[#touches].chapter_idx, 3)
Assert.eq(fetched[#fetched], 3)

-- books.path 只代表最近下载/落盘的章节；没有阅读进度时不能从第 50 章启动。
pending = nil
book_row = { path = tmp .. "/2.html" }
local first_path
Chapter.openWithUi({ type = "chapter" }, identity, {}, nil, ops, function(p)
    first_path = p
end)
Stubs.flush()
Assert.eq(first_path, tmp .. "/1.html")
Assert.eq(touches[#touches].chapter_idx, 1)
progress_ui.shown = 0
book_row = nil

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


-- 本地章节已存在时快开，不弹准备框；但必须补登记身份，修复早于 chapters 表的缓存。
local fast_path
local touch_before = #touches
Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p)
    fast_path = p
end)
Stubs.flush()
Assert.eq(fast_path, tmp .. "/2.html")
Assert.eq(progress_ui.shown, 0)
Stubs.flush()
Assert.eq(#touches, touch_before + 1)
Assert.eq(touches[#touches].chapter_idx, 2)

-- 快开登记失败不能继续把未知 .moon 文件交给 Reader。
touch_error = "register failed"
local failed_path, failed_err
Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops, function(p, err)
    failed_path, failed_err = p, err
end)
Stubs.flush()
Assert.is_nil(failed_path)
Assert.eq(failed_err, "register failed")
touch_error = nil

-- 用户关掉准备框（取消键 / 点外 / 返回键）：取消源任务并回调「已取消」。
os.remove(tmp .. "/2.html")
local user_err, toc_cancelled = nil, 0
Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, {
    loadToc = function() return { cancel = function() toc_cancelled = toc_cancelled + 1 end } end,
    fetchContent = function() end,
}, function(_, err) user_err = err end)
Stubs.flush()
local prep = Themed.last("progress_dialog")
Assert.not_nil(prep.on_cancel)
prep:dismiss()
Assert.eq(toc_cancelled, 1)
Assert.eq(user_err, "已取消")
progress_ui.shown = 0

-- 没有 book（冷启动直接按 identity 打开）：准备框标题退回 stable_id，不能报错。
os.remove(tmp .. "/2.html")
Chapter.openWithUi({ type = "chapter" }, identity, nil, { chapter_idx = 2 }, {
    loadToc = function() return { cancel = function() end } end,
    fetchContent = function() end,
}, function() end)
Stubs.flush()
local bare = Themed.last("progress_dialog")
Assert.eq(bare.title, identity.stable_id)
bare:dismiss()
progress_ui.shown = 0

-- 未连网：直接失败给出提示，不走 runWhenOnline（用户拒开 Wi-Fi 时它永不回调）。
network.connected = false
progress_ui.shown = 0
os.remove(tmp .. "/2.html")
local offline_path, offline_err
Chapter.openWithUi({ type = "chapter" }, identity, {}, { chapter_idx = 2 }, ops,
    function(p, err) offline_path, offline_err = p, err end)
Stubs.flush()
Assert.is_nil(offline_path)
Assert.not_nil(offline_err)
Assert.eq(network.waited, 0)
Assert.eq(progress_ui.shown, 0)
network.connected = true

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

-- 未连网预取：不请求正文，整批按失败回报，交给任务队列等网络。
for i = 1, 3 do os.remove(tmp .. "/" .. i .. ".html") end
network.connected = false
local offline_fetches, offline_stats = 0, nil
Chapter.prefetchAsync(identity, { title = "书" }, toc, 0, 3, {
    fetchContent = function() offline_fetches = offline_fetches + 1 end,
}, function(done, all, bad, err) offline_stats = { done, all, bad, err } end)
Stubs.flush()
Assert.eq(offline_fetches, 0)
Assert.eq(offline_stats[1], 0)
Assert.eq(offline_stats[2], 3)
Assert.eq(offline_stats[3], 3)
Assert.not_nil(offline_stats[4])
Assert.eq(network.waited, 0)
network.connected = true

-- 缓存范围：nil 全本；起点取 chapter_idx，其次按 fraction 折算，越界夹到目录内；count 缺省到结尾。
local ten = {}
for i = 1, 10 do ten[i] = { title = "第" .. i .. "章" } end
local function span(toc, range) return table.concat({ Chapter.cacheRange(toc, range) }, ",") end
Assert.eq(span(ten, nil), "0,10")
Assert.eq(span(ten, {}), "0,10", "无进度从第 1 章到结尾")
Assert.eq(span(ten, { chapter_idx = 4 }), "3,7", "含当前章")
Assert.eq(span(ten, { chapter_idx = 4, count = 3 }), "3,3")
Assert.eq(span(ten, { chapter_idx = 4, fraction = 0.9 }), "3,7", "chapter_idx 优先于 fraction")
Assert.eq(span(ten, { fraction = 0.35, count = 20 }), "3,20", "count 超出由 prefetchAsync 夹到目录尾")
Assert.eq(span(ten, { fraction = 1 }), "9,1")
Assert.eq(span(ten, { chapter_idx = 99 }), "9,1")
Assert.eq(span(ten, { chapter_idx = 0 }), "0,10")
Assert.eq(span({}, { chapter_idx = 3 }), "0,0", "空目录")

-- 源自己落好的章节文件（漫画 CBZ）原样登记，不写 HTML
do
    local got
    Chapter.openAsync({ type = "chapter" }, identity, {}, { chapter_idx = 1 }, {
        loadToc = ops.loadToc,
        fetchContent = function(_, _item, cb) cb({ file = "/x/ch.cbz" }) end,
    }, function(p) got = p end)
    Assert.eq(got, "/x/ch.cbz")
    Assert.eq(touches[#touches].path, "/x/ch.cbz")
end

for name in lfs.dir(tmp) do
    if name ~= "." and name ~= ".." then os.remove(tmp .. "/" .. name) end
end
lfs.rmdir(tmp)
for _, name in ipairs({
    "utils.paths", "book.progress_db", "book.books_db", "book.store", "source.chapter",
    "ui/network/manager",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
