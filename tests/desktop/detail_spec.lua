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
local downloaded = {} -- stable_id → true
package.preload["book.books_db"] = function()
    return {
        isDownloaded = function(_source_id, stable_id) return downloaded[stable_id] == true end,
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
downloaded.b1 = true
local tools, primary = Detail.actionPlan(unread, local_src)
Assert.eq(ids(tools), "edit,scrape,read,delete", "本地原书已有文件：无下载")
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
Assert.eq(ids(tools), "download,clear_cache,unread,delete", "章节源已缓存仍可继续缓存后面的章")

-- 整本书源：没登记文件给下载（WebDAV / moon 未下载），离线副本在 cache 内给清理，已在本地书库目录两者都没有
local online_book_src = setmetatable({ id = "moon", type = "book" }, SourceDefaults)
local moon_book = { source_id = "moon", stable_id = "m1", read_state = 0 }
tools = Detail.actionPlan(moon_book, online_book_src)
Assert.eq(ids(tools), "download_book,read,delete")
moon_book.cached = true
tools = Detail.actionPlan(moon_book, online_book_src)
Assert.eq(ids(tools), "clear_cache,read,delete")
local dav_book = { source_id = "local", stable_id = "webdav://a.epub", read_state = 0 }
Assert.eq(ids(Detail.actionPlan(dav_book, local_src)), "edit,scrape,download_book,read,delete")
downloaded["webdav://a.epub"] = true
Assert.eq(ids(Detail.actionPlan(dav_book, local_src)), "edit,scrape,read,delete", "已下载到本地书库目录")

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
for _, label in ipairs({ "编辑", "刮削", "已读", "删除", "开始阅读", "暂无阅读记录" }) do
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

-- 标记已读：写库、打脏、通知书架已变，在线就当场推这本书的进度；关窗时桌面重建。
local online = true
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
local progress_pushes = {}
resolved = {
    id = "wechat",
    syncProgressAsync = function(_, opts) progress_pushes[#progress_pushes + 1] = opts end,
}
Detail.open(desktop, "library", { source_id = "wechat", stable_id = "w2", title = "书一", read_state = 0 })
page = desktop.detail
page:toggleRead()
Assert.eq(set_read[1], "wechat")
Assert.eq(set_read[2], "w2")
Assert.is_true(set_read[3])
Assert.len(progress_pushes, 1)
Assert.eq(progress_pushes[1].identity.stable_id, "w2")
Assert.is_true(progress_pushes[1].dirty_only)
online = false
page.book.read_state = 0
page:toggleRead()
Assert.len(progress_pushes, 1, "离线只写库，等推脏行")
online = true
Assert.is_true(page._dirty)
Assert.eq(desktop.events[1], "shelf_changed")
page.book.read_state = 1
page:toggleRead()
Assert.is_false(set_read[3])
desktop.events = {}
page:close()
Assert.eq(desktop.events[1], "detail_dirty")
Assert.eq(desktop.updates, 1)
package.loaded["ui/network/manager"] = nil
resolved = local_src

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

-- 全本缓存：入队跟随，进度来自源回调；同书在缓存时再入队拒绝、清理缓存拒绝。
resolved = chapter_src
local cache_calls = {}
chapter_src.cacheAllChaptersAsync = function(_self, identity, progress, cb, range)
    cache_calls[#cache_calls + 1] = { identity = identity, cb = cb, range = range }
    progress(3, 35)
    return { cancel = function() end }
end
page:cacheAllChapters()
local cache_job = followed[#followed]
Assert.eq(cache_job.kind, "cache")
Assert.eq(cache_job.title, "书一")
Assert.eq(cache_job.total, 35)
Assert.eq(cache_calls[1].identity.stable_id, "w2")
page:cacheAllChapters()
Assert.eq(followed[#followed], "running")
Assert.len(cache_calls, 1, "同一本书不重复开跑")
cleared = nil
page:clearCache()
Themed.last("confirm").ok_callback()
Assert.is_nil(cleared)
Assert.eq(Themed.last("toast").text, "本书正在后台缓存，请稍后再试")
-- 限流可重试：退避等待、不提示；不可重试的失败按部分完成提示。
cache_calls[1].cb(false, 34, "HTTP 425", 35, 1)
Assert.eq(cache_job.state, "retry_wait")
cache_job.cancel()
page:cacheAllChapters()
cache_calls[2].cb(false, 30, "网络错误", 35, 5)
Assert.eq(Themed.last("toast").text, "缓存部分完成：30 / 35 章，5 章失败\n网络错误")
page:cacheAllChapters()
cache_calls[3].cb(true, 35, nil, 35, 0)
Assert.eq(Themed.last("toast").text, "缓存完成：35 / 35 章")
Assert.is_nil(cache_calls[3].range, "缺省全本")
Assert.is_nil(require("workers.tasks").get("cache\0wechat\0w2"))
page:clearCache()
Themed.last("confirm").ok_callback()
Assert.eq(cleared[2], "w2", "缓存结束后可清理")

-- 选择缓存范围：起点取本地进度；全本不带 range，到结尾不带 count，往后 N 章带 count。
local pending = { chapter_idx = 7, fraction = 0.2 }
package.loaded["book.progress_db"] = { get = function() return pending end }
local function pickCache(row, col)
    page:chooseCacheRange()
    local sheet = Themed.last("sheet")
    Assert.eq(sheet.title, "缓存章节")
    local item = sheet.items[row]
    if col then item = item.buttons[col] end
    item.callback()
    local call = cache_calls[#cache_calls]
    call.cb(true, 1, nil, 1, 0)
    return call.range, item.text
end
local range, label = pickCache(1)
Assert.eq(label, "全本缓存")
Assert.is_nil(range)
range, label = pickCache(2)
Assert.eq(label, "从当前进度缓存到结尾")
Assert.eq(range.chapter_idx, 7)
Assert.eq(range.fraction, 0.2)
Assert.is_nil(range.count)
for _idx, case in ipairs({ { 3, 1, 10 }, { 3, 2, 20 }, { 4, 1, 50 }, { 4, 2, 100 } }) do
    range, label = pickCache(case[1], case[2])
    Assert.eq(label, "往后 " .. case[3] .. " 章")
    Assert.eq(range.chapter_idx, 7)
    Assert.eq(range.count, case[3])
end
pending = nil
range = pickCache(3, 1)
Assert.is_nil(range.chapter_idx, "无进度：从第 1 章起")
Assert.eq(range.count, 10)
package.loaded["book.progress_db"] = nil
resolved = nil

-- 整本下载：离线直接提示；在线入队，走属主源 openBookAsync 只落盘不开书，成功通知书架已变。
online = false
package.loaded["ui/network/manager"] = { isConnected = function() return online end }
local open_calls = {}
resolved = {
    id = "local", type = "book",
    openBookAsync = function(_self, identity, opts, cb)
        open_calls[#open_calls + 1] = { identity = identity, opts = opts, cb = cb }
        return { cancel = function() end }
    end,
}
Detail.open(desktop, "library", { source_id = "local", stable_id = "webdav://d.epub", title = "云书" })
local dl_page = desktop.detail
dl_page:downloadBook()
Assert.len(open_calls, 0, "离线不入队")
Assert.eq(Themed.last("toast").text, "网络不可用，请先连接 Wi-Fi")
online = true
local before_followed = #followed
dl_page:downloadBook()
Assert.eq(#followed, before_followed + 1)
Assert.eq(followed[#followed].kind, "cache")
Assert.eq(open_calls[1].identity.stable_id, "webdav://d.epub")
Assert.is_nil(open_calls[1].opts)
desktop.events = {}
open_calls[1].cb("/lib/d.epub")
Assert.eq(Themed.last("toast").text, "下载完成")
Assert.eq(desktop.events[1], "shelf_changed")
Assert.is_nil(require("workers.tasks").get("cache\0local\0webdav://d.epub"))
dl_page:downloadBook()
open_calls[2].cb(nil, "WebDAV 下载失败")
Assert.eq(Themed.last("toast").text, "WebDAV 下载失败")
dl_page:close()
package.loaded["ui/network/manager"] = nil
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
Assert.contains(Kit.texts(page), "开始日期")
Assert.contains(Kit.texts(page), "—", "没有进度时预计剩余 / 读完都空着")
page:close()

-- 预计剩余按进度比例外推；日均按最近记录跨的日历天数摊（没读的日子也算）。
local noon = os.time{ year = os.date("*t").year, month = os.date("*t").month, day = os.date("*t").day, hour = 12 }
stats.summary = { pages = 10, total_seconds = 600, last_read = noon, first_read = noon - 9 * 86400 }
stats.daily = {
    { ymd = os.date("%Y-%m-%d", noon), seconds = 300 },
    { ymd = os.date("%Y-%m-%d", noon - 9 * 86400), seconds = 300 },
}
Detail.open(desktop, "library", { source_id = "local", stable_id = "b9", title = "统计书", percent = 25 })
texts = Kit.texts(desktop.detail)
Assert.contains(texts, os.date("%Y-%m-%d", noon - 9 * 86400), "开始日期取最早一条记录")
Assert.contains(texts, "1800s", "读了 25% 用 600 秒，剩下 75% 要 1800 秒")
Assert.contains(texts, os.date("%Y-%m-%d", noon + 30 * 86400), "10 天读 600 秒，日均 60 秒，还要 30 天")
desktop.detail:close()
stats.summary, stats.daily = nil, {}

-- Hero 下方信息条：图标 + 文字一行排开，带属主源名（混合模式同屏多源时可读）。
resolved = { id = "wechat" }
Detail.open(desktop, "library", {
    source_id = "wechat", stable_id = "b1", title = "书", category = "科幻,硬科幻", series = "三体",
})
local texts_w = Kit.texts(desktop.detail)
Assert.contains(texts_w, "微信读书")
Assert.contains(texts_w, "科幻 · 硬科幻")
Assert.contains(texts_w, "三体")
Assert.contains(texts_w, "source", "图标走主题 Icon")
for _idx, text in ipairs(texts_w) do
    Assert.is_true(text ~= "folder" and text ~= "article", "章节源没有文件项：" .. text)
end
Assert.eq(hero_opts.opts.title_lines, 3)
Assert.is_true(hero_opts.opts.show_desc, "图书馆简介在 Hero 右栏")
Assert.is_nil(hero_opts.opts.on_info_tap, "无简介时右栏同封面")
Assert.eq(hero_opts.source.id, "wechat")
desktop.detail:close()

-- 整本书文件：格式、大小、加入日期、文件名；点 Hero 右栏看简介全文。
resolved = local_src
local added = os.time({ year = 2026, month = 9, day = 1, hour = 12 })
Detail.open(desktop, "library", {
    source_id = "local", stable_id = "/books/长书.epub", path = "/books/长书.epub", title = "长书",
    filesize = 2048, inserted_at = added, intro = "全文简介",
})
texts_w = Kit.texts(desktop.detail)
Assert.contains(texts_w, "local")
Assert.contains(texts_w, "EPUB")
Assert.contains(texts_w, require("util").getFriendlySize(2048))
Assert.contains(texts_w, "2026-09-01 加入")
Assert.contains(texts_w, "长书.epub")
Assert.contains(texts_w, "暂无阅读记录")
desktop.detail[1]:paintTo(Kit.canvas(), 0, 0)
hero_opts.opts.on_info_tap()
Assert.eq(Themed.last("text_viewer").title, "长书")
Assert.eq(Themed.last("text_viewer").text, "全文简介")
desktop.detail:close()

-- 一行放不下：从放不下的那项起整项隐藏，不折行。
Detail.open(desktop, "library", {
    source_id = "local", stable_id = "/books/长书.epub", path = "/books/长书.epub", title = "长书",
    filesize = 2048, series = string.rep("系", 60),
})
texts_w = Kit.texts(desktop.detail)
Assert.contains(texts_w, "EPUB")
for _idx, text in ipairs(texts_w) do
    Assert.is_true(text ~= string.rep("系", 60) and text ~= "长书.epub", "超宽项及其后各项隐藏：" .. text)
end
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

-- 库内书缺简介：在线时向属主源要一次详情（源负责落库），只并简介 / 作者；有简介、离线都不请求。
local asked, owner_cb, owner_cancelled = 0, nil, false
local net_online = true
package.loaded["ui/network/manager"] = { isConnected = function() return net_online end }
resolved = { id = "ext.kavita", getDetailAsync = function(_self, identity, cb)
    asked = asked + 1
    Assert.eq(identity.stable_id, "k1")
    Assert.eq(identity.source, resolved)
    owner_cb = cb
    return { cancel = function() owner_cancelled = true end }
end }
db_row = { title = "K" }
local kbook = { source_id = "ext.kavita", stable_id = "k1", title = "K", percent = 30 }
Detail.open(desktop, "library", kbook)
page = desktop.detail
Assert.eq(asked, 1)
db_row = { title = "K", intro = "补到的简介", authors = "甲" }
Kit.dirty = {}
owner_cb({})
Assert.eq(page.book.intro, "补到的简介")
Assert.eq(page.book.authors, "甲")
Assert.eq(page.book.percent, 30, "列表专有字段不丢")
Assert.is_true(dirtied(page))
page:close()
Assert.is_false(owner_cancelled)
Detail.open(desktop, "library", { source_id = "ext.kavita", stable_id = "k1", title = "K" })
desktop.detail:close()
Assert.eq(asked, 1, "已有简介不请求")
db_row, net_online = { title = "K" }, false
Detail.open(desktop, "library", { source_id = "ext.kavita", stable_id = "k1", title = "K" })
desktop.detail:close()
Assert.eq(asked, 1, "离线不请求")
net_online = true
Detail.open(desktop, "library", { source_id = "ext.kavita", stable_id = "k1", title = "K" })
desktop.detail:close()
Assert.is_true(owner_cancelled, "关窗取消在飞请求")
db_row = nil

-- 桌面已关：关详情不再碰桌面。
desktop.closed = true
Detail.open(desktop, "library", { source_id = "local", stable_id = "b1", title = "书一" })
desktop.detail._dirty = true
desktop.updates = 0
desktop.detail:close()
Assert.eq(desktop.updates, 0)
