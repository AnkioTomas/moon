--[[--
source.moon 门面离线用例：书架同步 / 本地查询 / onEvent 事件分发 / progress 映射。

书架同步经远端 listQuery 拉全量；书架展示与筛选则必须经过 book.catalog。
onEvent 的 KOReader UI 依赖按约定函数内延迟加载，这里用 preload 打桩。

@module tests.source.moon_spec
--]]

local Assert = require("support.assert")

-- 假客户端：记录入参、回放预设响应
local rec = {}
local client = {}
local lfs = require("libs/libkoreader-lfs")
local open_dir = os.tmpname() .. ".moon-open"
os.remove(open_dir)
assert(lfs.mkdir(open_dir))

package.preload["utils.settings"] = function()
    return {
        getSource = function() return {} end,
    }
end

package.preload["source.moon.client"] = function()
    return {
        new = function() return client end,
    }
end

package.preload["utils.paths"] = function()
    return {
        ensureBookWork = function() end,
        bookWorkDir = function() return open_dir end,
    }
end

package.preload["db.book"] = function()
    return { libraryStableIdsBySource = function() return { "a.epub", "b.epub" } end }
end

package.preload["book.catalog"] = function()
    return {
        listLibraryAsync = function(source_id, opts, cb)
            rec.catalog_source = source_id
            rec.catalog_opts = opts
            cb({ data = { { stable_id = "local-a.epub", percent = 42 } }, count = 1 })
            return { cancel = function() end }
        end,
        filtersAsync = function(source_id, cb)
            rec.catalog_source = source_id
            cb({ data = { category = { "小说", "技术" }, series = { "第一辑" } } })
            return { cancel = function() end }
        end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        runWhenOnline = function(_, fn) fn() end,
    }
end

local dialog = { shown = 0, closed = 0, progress = nil }
package.preload["ui/widget/progressbardialog"] = function()
    return {
        new = function(_, opts)
            return {
                show = function() dialog.shown = dialog.shown + 1 end,
                close = function() dialog.closed = dialog.closed + 1 end,
                reportProgress = function(_, bytes) dialog.progress = bytes end,
                opts = opts,
            }
        end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, opts) return opts end }
end

local touches = {}
package.preload["book.store"] = function()
    return {
        touchAsync = function(path, identity, _, cb)
            touches[#touches + 1] = { path = path, identity = identity }
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

-- onEvent 延迟加载的 UI 依赖：记录调用
local sync = { push_calls = 0, last_source = nil, push_args = nil }

package.preload["book.stats"] = function()
    return {
        pullInBackground = function() end,
        syncAsync = function(self, _, cb)
            sync.push_calls = sync.push_calls + 1
            sync.pull_calls = (sync.pull_calls or 0) + 1
            sync.last_source = self
            cb({ pulled = 1, pushed = 1 })
            return { cancel = function() end }
        end,
        push = function(self, cb)
            sync.push_calls = sync.push_calls + 1
            sync.last_source = self
            if cb then cb(true, { ok = true }) end
        end,
        pull = function(self, cb)
            sync.pull_calls = (sync.pull_calls or 0) + 1
            sync.last_source = self
            if cb then cb(true, { imported = 0 }) end
        end,
    }
end

-- 假 client 方法（moon.lua 一律冒号调用，首参是 client 自身）
function client:configured()
    return true
end

function client:listBooksAsync(query, cb)
    rec.query = query
    cb(rec.list_wire, rec.list_err)
    return { cancel = function() end }
end

function client:filtersAsync(cb)
    cb(rec.filters_wire, rec.filters_err)
    return { cancel = function() end }
end

function client:getProgressAsync(stable_id, cb)
    rec.progress_id = stable_id
    cb(rec.progress_wire, rec.progress_err)
    return { cancel = function() end }
end

function client:updateProgressAsync(payload, cb)
    rec.put_payload = payload
    if rec.put_err then
        cb(nil, rec.put_err)
    else
        cb({ ok = true })
    end
    return { cancel = function() end }
end

function client:syncAnnotationsAsync(payload, cb)
    rec.annotations_payload = payload
    cb({ ok = true })
    return { cancel = function() end }
end

function client:syncStatsAsync(payload, cb)
    rec.stats_payload = payload
    cb({ ok = true })
    return { cancel = function() end }
end

function client:getBookStatsAsync(stable_id, cb)
    rec.stats_ids = rec.stats_ids or {}
    rec.stats_ids[#rec.stats_ids + 1] = stable_id
    cb({ data = { page_stat = {
        { page = #rec.stats_ids, start_time = 1000 + #rec.stats_ids, duration = 30, total_pages = 100 },
    } } })
    return { cancel = function() end }
end

function client:downloadBookAsync(stable_id, path, on_progress, cb)
    rec.download_count = (rec.download_count or 0) + 1
    rec.download_id = stable_id
    rec.download_path = path
    if rec.defer_download then
        rec.download_done = cb
        rec.download_progress = on_progress
        return { cancel = function() end }
    end
    local file = assert(io.open(path, "wb"))
    file:write(rec.download_body or "PK\003\004book")
    file:close()
    if on_progress then on_progress(8) end
    cb(rec.download_ok ~= false, rec.download_err)
    return { cancel = function() end }
end

local Moon = require("source.moon")
local src = Moon.new()

local function resetRec()
    for k in pairs(rec) do rec[k] = nil end
end

-- syncBooksAsync：完整书架拉取后写入本地库
do
    resetRec()
    rec.list_wire = { data = { { filename = "a.epub", title = "A" } }, count = 1 }
    local result
    src:syncBooksAsync(nil, function(value) result = value end)
    Assert.eq(rec.query.page, 1)
    Assert.eq(rec.query.pageSize, 200)
    Assert.eq(rec.query.search, "")
    Assert.eq(rec.query.series, "")
    Assert.eq(rec.query.category, "")
    Assert.is_nil(rec.query.favorite)
    Assert.is_nil(rec.query.finished)
    Assert.is_nil(rec.query.author)
    Assert.eq(rec.reconciled_source, "moon")
    Assert.eq(rec.reconciled_books[1].stable_id, "a.epub")
    Assert.eq(result.pulled, 1)
end

-- 首页进入按 5 分钟节流检查书架；图书馆手动刷新走源事件并强制请求。
do
    resetRec()
    rec.list_wire = { data = { { filename = "home.epub", title = "Home" } }, count = 1 }
    local rebuilds = 0
    local desktop = {
        source = src,
        tab = "home",
        rebuild = function() rebuilds = rebuilds + 1 end,
        -- 真实实现是 Home.invalidate：清状态后仅在首页时重建
        invalidateHome = function(self)
            self._home_state = nil
            self._home_loaded = false
            if self.tab == "home" then rebuilds = rebuilds + 1 end
        end,
    }
    src:onEvent("home_open", desktop)
    Assert.is_true(rec.query ~= nil)
    local first_query = rec.query
    resetRec()
    src:onEvent("home_open", desktop)
    Assert.is_nil(rec.query)
    src:onEvent("library_refresh_request", desktop)
    Assert.is_true(rec.query ~= nil)
    Assert.eq(rebuilds, 2)
    rec.query = first_query
end


-- openBookAsync：Moon 自己完成缓存、下载、校验、并发合并和落库。
do
    local path = open_dir .. "/book.epub"
    os.remove(path)
    os.remove(path .. ".part")
    resetRec()
    touches = {}
    dialog.shown, dialog.closed, dialog.progress = 0, 0, nil

    local opened, open_err
    src:openBookAsync({
        source_id = "moon",
        stable_id = "library/a.epub",
        book = { title = "A", fileSize = 8 },
    }, nil, function(p, err) opened, open_err = p, err end)
    Assert.eq(rec.download_count, 1)
    Assert.eq(rec.download_id, "library/a.epub")
    Assert.eq(rec.download_path, path .. ".part")
    Assert.eq(dialog.progress, 8)
    Assert.eq(opened, path)
    Assert.is_nil(open_err)
    Assert.eq(touches[1].path, path)

    resetRec()
    opened = nil
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p)
        opened = p
    end)
    Assert.is_nil(rec.download_count)
    Assert.eq(opened, path)

    os.remove(path)
    resetRec()
    rec.defer_download = true
    local first, second
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p) first = p end)
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p) second = p end)
    Assert.eq(rec.download_count, 1)
    local file = assert(io.open(path .. ".part", "wb"))
    file:write("PK\003\004book")
    file:close()
    rec.download_done(true)
    Assert.eq(first, path)
    Assert.eq(second, path)

    os.remove(path)
    resetRec()
    rec.download_body = "XXXX"
    src:openBookAsync({ source_id = "moon", stable_id = "library/a.epub" }, nil, function(p, err)
        opened, open_err = p, err
    end)
    Assert.is_nil(opened)
    Assert.eq(open_err, "下载文件校验失败")
    Assert.is_nil(lfs.attributes(path .. ".part"))
end

-- 书架查询：所有参数原样交给本地 catalog，不触发 Moon HTTP client。
do
    resetRec()
    local result
    local opts = {
        page = 3,
        page_size = 10,
        search = "科幻",
        series = "s",
        category = "c",
    }
    src:listLibraryAsync(opts, function(r) result = r end)
    Assert.is_nil(rec.query)
    Assert.eq(rec.catalog_source, "moon")
    Assert.eq(rec.catalog_opts, opts)
    Assert.eq(result.count, 1)
    Assert.eq(result.data[1].stable_id, "local-a.epub")
    Assert.eq(result.data[1].percent, 42)
end

-- 筛选项同样只来自本地 catalog。
do
    resetRec()
    local result
    src:filtersAsync(function(r) result = r end)
    Assert.is_nil(rec.filters_wire)
    Assert.eq(rec.catalog_source, "moon")
    Assert.len(result.data.category, 2)
    Assert.eq(result.data.category[1], "小说")
    Assert.len(result.data.series, 1)
    Assert.eq(result.data.series[1], "第一辑")
end

-- onEvent：阅读生命周期由 session 处理；这里只响应用户统计同步请求
do
    sync.push_calls = 0
    sync.pull_calls = 0

    src:onEvent("document_close")
    Assert.eq(sync.push_calls, 0)

    src:onEvent("suspend")
    Assert.eq(sync.push_calls, 0)

    src:onEvent("page_changed")
    Assert.eq(sync.push_calls, 0)

    src:onEvent("stats_sync_request")
    Assert.eq(sync.pull_calls, 1)
    Assert.eq(sync.push_calls, 1)
    Assert.eq(sync.last_source, src)
end

-- getProgressAsync：wire 表 → ProgressPosition（percent/100、chapter_idx、locator）
do
    resetRec()
    rec.progress_wire = { data = { percent = 42, chapter_idx = 3, locator = "ptr" } }
    local pos, err
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(rec.progress_id, "a.epub")
    Assert.eq(pos.fraction, 0.42)
    Assert.eq(pos.chapter_idx, 3)
    Assert.eq(pos.locator, "ptr")
end

-- getProgressAsync：data 为纯数字（百分数）也映射为 fraction
do
    resetRec()
    rec.progress_wire = { data = 55 }
    local pos
    src:getProgressAsync({ stable_id = "a.epub" }, function(p) pos = p end)
    Assert.eq(pos.fraction, 0.55)

    -- 服务端 /book/progress 回吐的是 spine 键，且 locator 过期时为空串
    rec.progress_wire = { data = { percent = 30, spine = 5, locator = "", page = 9 } }
    src:getProgressAsync({ stable_id = "a.epub" }, function(p) pos = p end)
    Assert.eq(pos.fraction, 0.3)
    Assert.eq(pos.chapter_idx, 5)
    Assert.is_nil(pos.locator, "空串应归一成 nil")
end

-- getProgressAsync：拉取失败透传错误；wire 无法映射时报「进度为空」
do
    resetRec()
    rec.progress_err = { message = "无进度" }
    local pos, err
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "无进度")

    rec.progress_wire = "garbage"
    rec.progress_err = nil
    src:getProgressAsync({ stable_id = "a.epub" }, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "进度为空")
end

-- putProgressAsync：fraction 钳制、spine/percent 组装
do
    resetRec()
    local ok, err
    src:putProgressAsync({ stable_id = "a.epub" }, { fraction = 0.5, chapter_idx = 2 }, function(o, e)
        ok, err = o, e
    end)
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(rec.put_payload.filename, "a.epub")
    Assert.eq(rec.put_payload.frac, 0.5)
    Assert.eq(rec.put_payload.spine, 2)
    Assert.eq(rec.put_payload.page, 0)
    Assert.eq(rec.put_payload.percent, "50.00%")

    -- 精确坐标必须发出去：不发的话服务端永远存不到，拉回来只有会漂移的百分比
    src:putProgressAsync({ stable_id = "a.epub" }, {
        fraction = 0.5, chapter_idx = 2, page = 12, locator = "/body/p[7]",
    }, function() end)
    Assert.eq(rec.put_payload.locator, "/body/p[7]")
    Assert.eq(rec.put_payload.page, 12)

    -- fraction 超 1 按百分数钳制（42 → 0.42）；chapter_idx 缺省 spine = 0
    src:putProgressAsync({ stable_id = "b.epub" }, { fraction = 42 }, function() end)
    Assert.eq(rec.put_payload.frac, 0.42)
    Assert.eq(rec.put_payload.spine, 0)
    Assert.eq(rec.put_payload.percent, "42.00%")

    -- pos 缺省：fraction 0
    src:putProgressAsync({ stable_id = "b.epub" }, nil, function() end)
    Assert.eq(rec.put_payload.frac, 0)
    Assert.eq(rec.put_payload.percent, "0.00%")

    -- 失败透传
    rec.put_err = "网络故障"
    src:putProgressAsync({ stable_id = "b.epub" }, { fraction = 0.1 }, function(o, e)
        ok, err = o, e
    end)
    Assert.is_nil(ok)
    Assert.eq(err, "网络故障")
end

-- 注解同步：领域层只传 identity + annotations，Moon 源才映射后端 filename。
do
    resetRec()
    local ok
    src:pushNotesAsync({ source_id = "moon", stable_id = "a.epub", chapter_idx = 2 }, {
        { datetime = "2026-08-20", page = "/p" },
    }, function(res)
        ok = res
    end)
    Assert.not_nil(ok)
    Assert.eq(rec.annotations_payload.filename, "a.epub")
    Assert.is_nil(rec.annotations_payload.device_id)
    Assert.eq(rec.annotations_payload.annotations[1].page, "/p")
end

-- 统计同步：book.stats 只传领域记录，Moon 源负责 wire 与设备字段。
do
    resetRec()
    local response
    src:pushStatsAsync({
        { stable_id = "a.epub", page = 3, start_time = 1000, duration = 30, total_pages = 100 },
    }, function(res) response = res end)
    Assert.not_nil(response)
    Assert.eq(rec.stats_payload.books[1].filename, "a.epub")
    Assert.eq(rec.stats_payload.stats[1].filename, "a.epub")
    Assert.is_nil(rec.stats_payload.stats[1].stable_id)
end

-- 统计拉取：Moon 源逐本请求并映射成带身份的领域记录。
do
    resetRec()
    local rows
    src:pullStatsAsync(function(value) rows = value end)
    Assert.len(rec.stats_ids, 2)
    Assert.eq(rec.stats_ids[1], "a.epub")
    Assert.eq(rec.stats_ids[2], "b.epub")
    Assert.len(rows, 2)
    Assert.eq(rows[1].source_id, "moon")
    Assert.eq(rows[1].stable_id, "a.epub")
    Assert.eq(rows[2].stable_id, "b.epub")
    Assert.eq(rows[2].duration, 30)
end

-- 还原 preload/loaded，避免影响本文件之后的用例
for _, name in ipairs({
    "utils.settings",
    "utils.paths",
    "db.book",
    "source.moon.client",
    "ui/network/manager",
    "ui/widget/progressbardialog",
    "ui/widget/infomessage",
    "book.store",
    "book.stats",
    "source.moon",
}) do
    package.preload[name] = nil
    package.loaded[name] = nil
end
os.remove(open_dir .. "/book.epub")
os.remove(open_dir .. "/book.epub.part")
lfs.rmdir(open_dir)
