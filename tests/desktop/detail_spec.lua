--[[--
desktop.detail：主题全屏页；底栏动作规划、标记已读、清理缓存、属主源删除、编辑保存、
最近几天分页、书城加入书库；打开 / 关窗与桌面联动。

@module tests.desktop.detail_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")
local Kit = require("support.widget_stubs")
Kit.install("paper")
local Themed = require("support.theme_stubs")
Themed.install()

local Container = require("ui/widget/container/widgetcontainer")
local Geom = require("ui/geometry")

local hero_opts
package.preload["ui.widgets.book"] = function()
    return {
        title = function(book) return book.title or "" end,
        author = function() return "作者甲" end,
        pct = function(book) return tonumber(book.percent) or 0 end,
        desc = function(book) return book.intro or "" end,
    }
end
package.preload["ui.widgets.bookhero"] = function()
    return {
        widget = function(_, source, book, opts)
            hero_opts = { source = source, book = book, opts = opts }
            return Container:new{ dimen = Geom:new{ w = opts.width, h = 80 } }, 80
        end,
    }
end
package.preload["book.catalog"] = function()
    return { formatDuration = function(s) return tostring(s) .. "s" end }
end
local cleared
local clear_result = { true }
package.preload["book.store"] = function()
    return {
        rememberMany = function() end,
        isCached = function(book) return book and book.cached == true end,
        clearCache = function(source_id, stable_id)
            cleared = { source_id, stable_id }
            return clear_result[1], clear_result[2]
        end,
    }
end
local queue_tasks = {}
local cache_task
package.preload["source.cache_queue"] = function()
    return {
        spec = function() return cache_task end,
        has = function(source_id, stable_id)
            for _, task in ipairs(queue_tasks) do
                if task.source_id == source_id and task.stable_id == stable_id then return true end
            end
            return false
        end,
    }
end
local stats = { summary = nil, daily = {} }
package.preload["book.stats_db"] = function()
    return {
        summaryByBook = function() return stats.summary end,
        dailyByBook = function() return stats.daily end,
    }
end
local followed = {}
package.preload["workers.ui.task_dialog"] = function()
    return {
        start = function(spec)
            local task, reason = require("workers.tasks").enqueue(spec)
            followed[#followed + 1] = task or reason
        end,
    }
end
local resolved
-- 真实源都继承 SourceBase:capabilities；假源缺省为不具备任何能力。
local SourceDefaults = { __index = { capabilities = function() return {} end } }
package.preload["source.registry"] = function()
    return {
        resolve = function() return resolved and setmetatable(resolved, SourceDefaults) end,
        meta = function(id)
            if id == "wechat" then return { id = "wechat", name = "微信读书" } end
            return { id = id, name = id }
        end,
    }
end
local set_read, db_row, upserted
local upsert_ok = true
package.preload["book.books_db"] = function()
    return {
        setRead = function(source_id, stable_id, value)
            set_read = { source_id, stable_id, value }
            return true
        end,
        get = function() return db_row end,
        upsertLocal = function(row)
            upserted = row
            return upsert_ok
        end,
    }
end

local Detail = require("desktop.detail")

local function ids(tools)
    local out = {}
    for i, item in ipairs(tools) do out[i] = item.id end
    return table.concat(out, ",")
end

local local_src = {
    id = "local",
    type = "book",
    capabilities = function() return { edit = true, scrape = true } end,
}
local chapter_src = {
    id = "wechat",
    type = "chapter",
    capabilities = function() return { edit = false, scrape = false } end,
    cacheAllChaptersAsync = function() end,
}

-- 底栏动作规划。
local unread = { source_id = "local", stable_id = "b1", title = "书一", read_state = 0, percent = 12 }
local tools, primary = Detail.actionPlan(unread, local_src)
Assert.eq(ids(tools), "edit,scrape,read,delete")
Assert.eq(primary.id, "open")
Assert.eq(primary.text, "继续阅读")
unread.percent = 0
_, primary = Detail.actionPlan(unread, local_src)
Assert.eq(primary.text, "开始阅读")

local read_book = { source_id = "wechat", stable_id = "w1", title = "微信书", read_state = 1, percent = 100 }
tools, primary = Detail.actionPlan(read_book, chapter_src)
Assert.eq(ids(tools), "download,unread,delete")
Assert.eq(primary.text, "开始阅读")
read_book.cached = true
tools = Detail.actionPlan(read_book, chapter_src)
Assert.eq(ids(tools), "clear_cache,unread,delete")

-- 整本在线源：无下载入口，离线副本在 cache 内才给清理
local online_book_src = setmetatable({ id = "moon", type = "book" }, SourceDefaults)
local moon_book = { source_id = "moon", stable_id = "m1", read_state = 0 }
tools = Detail.actionPlan(moon_book, online_book_src)
Assert.eq(ids(tools), "read,delete")
moon_book.cached = true
tools = Detail.actionPlan(moon_book, online_book_src)
Assert.eq(ids(tools), "clear_cache,read,delete")

--- 模拟桌面：记录 updateView / onEvent。
local function newDesktop()
    local d = { plugin = {}, source = local_src, tab = "library", library = { state = { stale = true }, page = 3 },
        updates = 0, events = {} }
    d.updateView = function(self) self.updates = self.updates + 1 end
    d.onEvent = function(self, event) self.events[#self.events + 1] = event end
    return d
end

--- dirty 记录里有没有刷过这个窗口（按钮点按也会记一笔，不能只看最后一条）。
local function dirtied(widget)
    for _, d in ipairs(Kit.dirty) do
        if d.widget == widget then return true end
    end
    return false
end

-- 打开：全屏主题页登记到桌面；标题栏返回、工具行、主操作都画出来。
resolved = local_src
local desktop = newDesktop()
Detail.open(desktop, "library", { source_id = "local", stable_id = "b1", title = "书一", read_state = 0 })
local page = desktop.detail
Assert.eq(Kit.shown[#Kit.shown], page)
Assert.eq(page[1]:getSize().h, 800)
local texts = Kit.texts(page)
for _, label in ipairs({ "编辑", "刮削", "标记已读", "删除", "开始阅读", "暂无阅读记录" }) do
    Assert.contains(texts, label)
end
Assert.eq(Kit.buttons(page)[1].icon, "arrow_back")

-- 返回键关窗：清引用，数据没变只重画桌面。
Kit.dirty = {}
Kit.buttons(page)[1]:onTapThemeButton()
Assert.is_true(page.closed)
Assert.is_nil(desktop.detail)
Assert.eq(desktop.updates, 0)
Assert.is_true(dirtied(desktop))

-- 标记已读：写库、打脏、通知书架已变；关窗时桌面重建。
Detail.open(desktop, "library", { source_id = "wechat", stable_id = "w2", title = "书一", read_state = 0 })
page = desktop.detail
page:toggleRead()
Assert.eq(set_read[1], "wechat")
Assert.eq(set_read[2], "w2")
Assert.is_true(set_read[3])
Assert.is_true(page._dirty)
Assert.eq(desktop.events[1], "shelf_changed")
page.book.read_state = 1
page:toggleRead()
Assert.is_false(set_read[3])
desktop.events = {}
page:close()
Assert.eq(desktop.events[1], "detail_dirty")
Assert.eq(desktop.updates, 1)

-- 清理缓存：确认后按身份清，成功重读并打脏；本书在后台缓存队列时拒绝
Detail.open(desktop, "library", { source_id = "wechat", stable_id = "w2", title = "书一", read_state = 0 })
page = desktop.detail
page:clearCache()
local confirm = Themed.last("confirm")
Assert.eq(confirm.text, "清理《书一》的本地缓存？\n正文、章节与图片需重新下载。")
confirm.ok_callback()
Assert.eq(cleared[1], "wechat")
Assert.eq(cleared[2], "w2")
Assert.eq(Themed.last("toast").text, "缓存已清理")
Assert.is_true(page._dirty)
clear_result = { true, "partial" }
page:clearCache()
Themed.last("confirm").ok_callback()
Assert.eq(Themed.last("toast").text, "部分缓存文件未能删除")
clear_result = { false }
page:clearCache()
Themed.last("confirm").ok_callback()
Assert.eq(Themed.last("toast").text, "清理缓存失败")
clear_result = { true }
cleared = nil
queue_tasks = { { source_id = "wechat", stable_id = "w2" } }
page:clearCache()
Themed.last("confirm").ok_callback()
Assert.is_nil(cleared)
Assert.eq(Themed.last("toast").text, "本书正在后台缓存，请稍后再试")
queue_tasks = {}

-- 全本缓存：CacheQueue 造的任务交给 task_dialog.start 入队跟随。
resolved = chapter_src
local cache_runs = 0
cache_task = {
    key = "cache-w2", kind = "cache",
    run = function() cache_runs = cache_runs + 1; return { cancel = function() end } end,
}
page:cacheAllChapters()
Assert.eq(followed[#followed], require("workers.tasks").get("cache-w2"))
Assert.eq(cache_runs, 1)
-- 同一本书已在缓存：拒绝，不重复开跑。
page:cacheAllChapters()
Assert.eq(followed[#followed], "running")
Assert.eq(cache_runs, 1)
require("workers.tasks").get("cache-w2").cancel()
resolved = nil

-- 删除：确认后走属主源，成功关详情、通知书架已变。
local deleted
resolved = {
    id = "wechat",
    type = "chapter",
    deleteBookAsync = function(_, identity, cb)
        deleted = identity
        cb(true)
    end,
}
desktop.events = {}
page:deleteBook()
Assert.eq(Themed.last("confirm").text, "确定删除《书一》？")
Themed.last("confirm").ok_callback()
Assert.eq(deleted.source_id, "wechat")
Assert.eq(deleted.stable_id, "w2")
Assert.eq(deleted.source, resolved)
Assert.is_true(page.closed)
Assert.is_nil(desktop.detail)
Assert.eq(desktop.events[1], "shelf_changed")

-- 删除失败：提示错误，页面不关。
resolved = { deleteBookAsync = function(_, _, cb) cb(false, "云端拒绝") end }
Detail.open(desktop, "library", { source_id = "wechat", stable_id = "w2", title = "书一" })
page = desktop.detail
page:deleteBook()
Themed.last("confirm").ok_callback()
Assert.eq(Themed.last("toast").text, "云端拒绝")
Assert.is_nil(page.closed)
page:close()

-- 编辑：主题 Input 四个字段，保存写库并通知属主源；移动走属主源（不看当前活跃源）；写库失败不上行并提示。
local meta_events, moved = {}, {}
resolved = {
    id = "local",
    capabilities = function() return { edit = true } end,
    onEvent = function(_, event, payload) meta_events[#meta_events + 1] = { event = event, payload = payload } end,
    moveBook = function(_, stable_id, category)
        moved[#moved + 1] = category
        return stable_id
    end,
}
desktop.source = { id = "wechat", capabilities = local_src.capabilities }
Detail.open(desktop, "library", { source_id = "local", stable_id = "webdav://a.epub", title = "旧名" })
page = desktop.detail
page:openEditor()
local input = Themed.last("input")
Assert.eq(input.fields[1].text, "旧名")
Assert.eq(input.fields[2].text, "作者甲")
db_row = { intro = "简介" }
input.callback("新名", "作者", "分类", "")
Assert.eq(upserted.title, "新名")
Assert.eq(upserted.intro, "简介")
Assert.len(meta_events, 1)
Assert.eq(meta_events[1].event, "book_meta_changed")
Assert.eq(meta_events[1].payload.identity.stable_id, "webdav://a.epub")
Assert.is_false(meta_events[1].payload.cover)
Assert.eq(Themed.last("toast").text, "元数据已更新")
Assert.eq(moved[1], "分类")
upsert_ok = false
page:saveMeta({ "又改", "", "", "" })
Assert.len(meta_events, 1, "写库失败不上行")
Assert.eq(Themed.last("toast").text, "保存元信息失败")
upsert_ok = true
db_row = nil
page:close()
desktop.source = local_src

-- 最近几天：放不下时分页，翻页只重建自己。
resolved = local_src
stats.summary = { pages = 10, total_seconds = 600, last_read = 0 }
stats.daily = {}
for i = 1, 40 do stats.daily[i] = { ymd = string.format("2026-09-%02d", i % 28 + 1), seconds = i } end
Detail.open(desktop, "library", { source_id = "local", stable_id = "b9", title = "统计书" })
page = desktop.detail
texts = Kit.texts(page)
Assert.contains(texts, "累计时长")
Assert.contains(texts, "600s")
Assert.contains(texts, "最近几天")
Assert.eq(page._daily_page, 1)
local pager_next
for _, b in ipairs(Kit.buttons(page)) do
    if b.icon == "chevron_right" then pager_next = b end
end
Kit.dirty = {}
pager_next:onTapThemeButton()
Assert.eq(page._daily_page, 2)
Assert.is_true(dirtied(page))
page:close()
stats.summary, stats.daily = nil, {}

-- Hero 副文案带属主源名（混合模式同屏多源时可读）。
resolved = { id = "wechat" }
Detail.open(desktop, "library", {
    source_id = "wechat", stable_id = "b1", title = "书", category = "科幻", series = "三体",
})
Assert.eq(hero_opts.opts.subtitle, "微信读书 · 科幻 · 三体")
Assert.eq(hero_opts.source.id, "wechat")
desktop.detail:close()

-- 书城：补拉完整详情，关窗时取消在飞请求；底栏只有「加入书库」，简介直下。
local detail_cb, detail_cancelled = nil, false
local install_cb, install_progress, installs = nil, nil, 0
package.preload["store.zlib"] = function()
    return {
        getDetailAsync = function(_, cb)
            detail_cb = cb
            return { cancel = function() detail_cancelled = true end }
        end,
        installAsync = function(_, _, on_progress, cb)
            installs = installs + 1
            install_progress, install_cb = on_progress, cb
            return { cancel = function() end }
        end,
    }
end
Detail.open(desktop, "store", { source_id = "zlib", stable_id = "1:abc", title = "书城书", filesize = 100 })
page = desktop.detail
Assert.contains(Kit.texts(page), "加入书库")
Kit.dirty = {}
detail_cb({ source_id = "zlib", stable_id = "1:abc", title = "书城书", intro = "完整简介", filesize = 100 })
Assert.eq(page.book.intro, "完整简介")
Assert.contains(Kit.texts(page), "简介")
Assert.is_true(dirtied(page))
page:close()
Assert.is_false(detail_cancelled, "补拉已落地，无需取消")
Detail.open(desktop, "store", { source_id = "zlib", stable_id = "1:abc", title = "书城书", filesize = 100 })
desktop.detail:close()
Assert.is_true(detail_cancelled)

-- 加入书库：进下载任务并前台跟随，下载中重复点被拒绝；进度按字节；完成提示并通知书架已变。
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, cb) cb() end, isConnected = function() return true end }
end
resolved = { id = "local", importBookAsync = function() end }
Detail.open(desktop, "store", { source_id = "zlib", stable_id = "1:abc", title = "书城书", filesize = 100 })
page = desktop.detail
desktop.events = {}
desktop.updates = 0
local follows = #followed
page:installStoreBook()
Assert.eq(installs, 1)
Assert.eq(#followed, follows + 1)
Assert.eq(followed[#followed].kind, "download")
page:installStoreBook()
Assert.eq(installs, 1)
Assert.eq(#followed, follows + 2)
Assert.eq(followed[#followed], "running")
local Tasks = require("workers.tasks")
install_progress(40)
Assert.eq(Tasks.tasks()[1].count, 40)
Assert.eq(Tasks.tasks()[1].total, 100)
install_cb(true, nil, "书城书.epub")
Assert.eq(Themed.last("toast").text, "已加入书库：书城书.epub")
Assert.eq(desktop.events[1], "shelf_changed")
Assert.eq(desktop.updates, 1)
Assert.eq(#Tasks.tasks(), 0)

-- 下载失败：提示错误，任务出列，可重新加入。
page:installStoreBook()
install_cb(nil, "网络错误")
Assert.eq(Themed.last("toast").text, "网络错误")
Assert.eq(#Tasks.tasks(), 0)
page:close()

-- 桌面已关：关详情不再碰桌面。
desktop.closed = true
Detail.open(desktop, "library", { source_id = "local", stable_id = "b1", title = "书一" })
desktop.detail._dirty = true
desktop.updates = 0
desktop.detail:close()
Assert.eq(desktop.updates, 0)
