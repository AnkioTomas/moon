--[[--
source.wechat 门面离线用例：进度 fraction↔percent 换算、chapter_uid 目录匹配、封面缓存。

client/auth/chapter/settings 用 package.preload 打桩；mapper 用真实实现。

@module tests.wechat_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, redundant-parameter, missing-parameter, inject-field, assign-type-mismatch, param-type-mismatch, cast-type-mismatch, return-type-mismatch, cast-local-type

local Assert = require("support.assert")

-- 顶掉网络/会话依赖；结束后统一还原
local saved_preload = {}
local function stub(name, factory)
    saved_preload[name] = package.preload[name]
    package.preload[name] = factory
    package.loaded[name] = nil
end

-- 可控假 client：每个用例按需覆写方法
local fake_client = {}
local chapter_open = {}
local chapter_range_html = "<html><body><p>" .. string.rep("正文", 8000) .. "</p></body></html>"
local chapter_fetches = 0
local progress_ui = { shown = 0, closed = 0, progress = {} }
local remembered_stats_books = {}
local existing_book

-- 目录缓存 payload 要真解码才能取出 chapter_uid
stub("json", function()
    return {
        decode = require("support.json_stub").decode,
        encode = require("support.json_stub").encode,
    }
end)

-- 目录缓存：按 stable_id 供给 payload，未登记的书一律未命中
local toc_payload = {}
stub("book.books_db", function()
    return {
        reconcile = function(_, books) remembered_stats_books.last_snapshot = books; return true, 0 end,
        stableIdsBySource = function() return {} end,
        get = function() return existing_book end,
        getMany = function(_, ids)
            local out = {}
            for _idx, id in ipairs(ids) do
                local row = (remembered_stats_books.local_rows or {})[id]
                if row then out[id] = row end
            end
            return out
        end,
        getToc = function(_, stable_id) return toc_payload[stable_id] end,
        setToc = function(_, stable_id, payload)
            toc_payload[stable_id] = payload
            return true
        end,
        libraryStableIdsBySource = function()
            return remembered_stats_books.local_library or {}
        end,
        pendingDeleteIds = function()
            local m = remembered_stats_books.marked_deleted
            return m and not remembered_stats_books.removed and { m.stable_id } or {}
        end,
        pendingShelfAddIds = function()
            return remembered_stats_books.pending_adds or {}
        end,
        unsynced = function()
            local m = remembered_stats_books.marked_deleted
            return m and not remembered_stats_books.removed and { m } or {}
        end,
        markSynced = function() return true end,
        setRead = function(source_id, stable_id, is_read)
            remembered_stats_books.set_read = {
                source_id = source_id, stable_id = stable_id, is_read = is_read,
            }
            return true
        end,
        remove = function(source_id, stable_id)
            remembered_stats_books.removed = { source_id = source_id, stable_id = stable_id }
            return true
        end,
    }
end)
local existing_progress
stub("book.progress_db", function()
    return {
        get = function() return existing_progress end,
        upsertRemote = function() return true end,
        unsynced = function() return {} end,
    }
end)
stub("book.chapters_db", function()
    return {
        deleteUnder = function(dir)
            remembered_stats_books.chapter_deleted_under = dir
            return true
        end,
    }
end)
stub("utils.settings", function()
    return {
        getSource = function() return {} end,
        saveSource = function() end,
    }
end)
stub("source.wechat.auth", function()
    return {
        hasSession = function() return true end,
        userLabel = function() return "tester" end,
        sessionHeaders = function() return { Cookie = "wr_skey=stub" } end,
    }
end)
fake_client.addToShelfAsync = function(_, _, cb)
    if cb then cb({ ok = true }) end
    return { cancel = function() end }
end
stub("source.wechat.client", function()
    return fake_client
end)
stub("source.wechat.chapter", function()
    return {
        fetchHtmlAsync = function(_, _, cb)
            chapter_fetches = chapter_fetches + 1
            cb(chapter_range_html, nil, chapter_range_html, "html")
            return { cancel = function() end }
        end,
        fetchContentAsync = function(_, _, cb)
            cb(nil, "试读")
            return { cancel = function() end }
        end,
    }
end)
stub("book.review_cache", function()
    return {
        hotspotsAsync = function(_, fetch, cb) return fetch(cb) end,
        pageAsync = function(_, _, _, fetch, cb) return fetch(cb) end,
    }
end)
stub("ui/network/manager", function()
    return { runWhenConnected = function(_, fn) fn() end, isConnected = function() return true end }
end)
stub("ui/widget/progressbardialog", function()
    return {
        new = function(_, opts)
            return {
                show = function() progress_ui.shown = progress_ui.shown + 1 end,
                close = function() progress_ui.closed = progress_ui.closed + 1 end,
                reportProgress = function(_, step)
                    progress_ui.progress[#progress_ui.progress + 1] = step
                end,
            }
        end,
    }
end)
stub("source.chapter", function()
    return {
        openWithUi = function(_, _, _, _, ops, cb)
            local dialog = require("ui/widget/progressbardialog"):new{}
            dialog:show()
            ops.progress = function(step) dialog:reportProgress(step) end
            ops.progress(1)
            ops.progress(4)
            dialog:close()
            chapter_open.ops = ops
            cb(chapter_open.path, chapter_open.err)
            return { cancel = function() chapter_open.cancelled = true end }
        end,
    }
end)
stub("book.store", function()
    return {
        rememberMany = function(books) remembered_stats_books = books end,
        markDeleted = function(source_id, stable_id)
            remembered_stats_books.marked_deleted = { source_id = source_id, stable_id = stable_id }
            return true
        end,
    }
end)

package.loaded["source.wechat"] = nil
local WeChat = require("source.wechat")

local REF = { source_id = "wechat", stable_id = "b1", book = { title = "微信书" } }

do
    local caps = WeChat.new():capabilities()
    Assert.is_false(caps.scrape)
    Assert.is_true(caps.edit)
    Assert.is_true(caps.stats_pull)
end

-- 年度不带日明细时，必须继续拉对应月份。
do
    local requests = {}
    fake_client.readStatsAsync = function(_, mode, base_time, cb)
        requests[#requests + 1] = { mode, base_time }
        if mode == "overall" then
            cb({
                totalReadTime = 7200,
                readTimes = {
                    ["1735689600"] = 3600,
                    ["1767225600"] = 3600,
                },
            })
        elseif mode == "annually" and base_time == 1735689600 then
            cb({
                baseTime = base_time,
                readTimes = { [tostring(base_time)] = 900 },
            })
        elseif mode == "annually" then
            cb({
                baseTime = base_time,
                dailyReadTimes = { [tostring(base_time)] = 900 },
            })
        else
            cb({
                baseTime = base_time,
                readTimes = { [tostring(base_time + 86400)] = 900 },
            })
        end
        return { cancel = function() end }
    end
    -- 书架：same 云端累计与本地快照一致 → 不拉；新近更新的 fresh 先拉；broken 拉失败只跳过
    fake_client.shelfSyncAsync = function(_, cb)
        cb({ bookProgress = {
            { bookId = "same", readingTime = 500, updateTime = 30 },
            { bookId = "broken", readingTime = 100, updateTime = 10 },
            { bookId = 42, readingTime = 2578, updateTime = 20 },
        } })
        return { cancel = function() end }
    end
    local readinfo = {}
    fake_client.readInfoAsync = function(_, book_id, cb)
        readinfo[#readinfo + 1] = book_id
        if book_id == "broken" then
            cb(nil, "网络错误")
        else
            cb({ readDetail = { totalReadingTime = 2578, data = {
                { readDate = 1790352000, readTime = 440 },
                { readDate = 1790438400, readTime = 134 },
                { readDate = 1790524800, readTime = 0 },
            } } })
        end
        return { cancel = function() end }
    end
    local StatsDB = require("book.stats_db")
    local real_book_totals = StatsDB.bookTotals
    StatsDB.bookTotals = function(source_id)
        Assert.eq(source_id, "wechat")
        return { same = 500, broken = 90 }
    end
    local result
    WeChat.new():pullStatsAsync(function(value) result = value end)
    StatsDB.bookTotals = real_book_totals
    fake_client.shelfSyncAsync, fake_client.readInfoAsync = nil, nil
    Assert.eq(readinfo[1], "42", "最近更新的书先拉，数字 bookId 统一为字符串")
    Assert.eq(readinfo[2], "broken")
    Assert.len(readinfo, 2, "云端累计没变的书不发 readinfo")
    Assert.len(result.replace.books, 1, "拉失败的书不替换，快照不变留待下次重试")
    Assert.eq(result.replace.books[1], "42")
    local book_days, book_total = {}, nil
    for _, row in ipairs(result.rows) do
        if row.stable_id == "42" and row.record_type == "book_day" then
            book_days[#book_days + 1] = row
            Assert.is_true(row.last_time > 0, "book_day 记拉取时间")
        end
        if row.stable_id == "42" and row.record_type == "book_total" then book_total = row.duration end
        if row.record_type == "day" then Assert.is_true(row.last_time > 0, "日桶记拉取时间") end
    end
    Assert.len(book_days, 2, "0 秒的日子不落行")
    Assert.eq(book_total, 2578, "快照取书架 readingTime，与触发拉取的值一致才能收敛")
    Assert.eq(requests[1][1], "overall")
    Assert.eq(requests[2][1], "annually")
    Assert.eq(requests[3][1], "annually")
    Assert.eq(requests[4][1], "monthly")
    Assert.eq(requests[4][2], 1735689600)
    Assert.len(requests, 4, "不再按周拉排行")
    Assert.not_nil(requests[2][2])
    Assert.not_nil(requests[3][2])
    Assert.eq(result.replace.mode, "ranges")
    Assert.len(result.replace.ranges, 4)
    local total, monthly_day
    for _, row in ipairs(result.rows) do
        if row.record_type == "total" then total = row.duration end
        if row.stable_id == "__wr:day:1735776000" then monthly_day = row.duration end
    end
    Assert.eq(total, 7200)
    Assert.eq(monthly_day, 900)
    fake_client.readStatsAsync = nil
end

toc_payload["bp"] = require("support.json_stub").encode({
    { idx = 1, source_idx = 3, uid = "u1", title = "一" },
    { idx = 2, source_idx = 5, uid = "u2", title = "二" },
})

-- pushStatsAsync 按 App 协议上报：一本书一个请求，行按小时分桶；成功才确认，失败停在原地。
do
    local Eink = require("source.wechat.eink")
    local real_creds, real_install = Eink.credentials, Eink.installId
    Eink.credentials = function() return { vid = "9", device_id = "dev1" } end
    Eink.installId = function() return "inst1" end
    local src = WeChat.new()
    local posted = {}
    local fail_book
    fake_client.guestTokenAsync = function(_, cb) cb("tok") end
    fake_client.getProgressAsync = function(_, _book_id, cb)
        cb({ book = { chapterUid = 12, chapterIdx = 9, chapterOffset = 23456,
            progress = 77, summary = "云端最新位置" } })
    end
    fake_client.reportAppReadAsync = function(_, body, cb)
        posted[#posted + 1] = body
        if body.bookId == fail_book then cb(nil, "boom") else cb({ succ = 1 }) end
    end
    local rows = {
        { id = 1, stable_id = "bp", chapter_idx = 1, chapter_fraction = 0.5, start_time = 3590, duration = 20 },
        { id = 2, stable_id = "bp", chapter_idx = 2, chapter_fraction = 0.25, start_time = 7300, duration = 10 },
        { id = 3, stable_id = "nobook", chapter_idx = 1, start_time = 100, duration = 5 },
    }
    local data, err
    src:pushStatsAsync(rows, function(value, e) data, err = value, e end)
    Assert.is_nil(err)
    Assert.len(posted, 2, "时长上报不依赖本地目录缓存")
    local body = posted[1]
    Assert.eq(body.bookId, "bp")
    Assert.eq(body.chapterUid, 12)
    Assert.eq(body.chapterIdx, 9, "保留云端最新章节，不用旧统计行的位置")
    Assert.eq(body.chapterOffset, 23456, "原文偏移可超过 10000")
    Assert.eq(body.currentProgress, 77)
    Assert.eq(body.summary, "云端最新位置")
    Assert.eq(body.deviceId, "dev1")
    Assert.eq(body.installId, "inst1")
    Assert.eq(body.readingTime, 30)
    Assert.len(body.hours, 3, "跨整点拆桶")
    Assert.eq(body.hours[1].startOfHour, 0)
    Assert.eq(body.hours[1].readingTime, 10)
    Assert.eq(#body.signature, 64)
    Assert.len(data.synced_ids, 3, "上报成功与无目录跳过的行都确认")

    posted, fail_book = {}, "bp"
    src:pushStatsAsync(rows, function(value, e) data, err = value, e end)
    Assert.is_nil(data)
    Assert.eq(err, "boom", "一本都没成功就报错，行留作脏行")

    fake_client.guestTokenAsync, fake_client.reportAppReadAsync, fake_client.getProgressAsync = nil, nil, nil
    Eink.credentials, Eink.installId = real_creds, real_install
end

-- 开章与拉取结束都不抢写云端进度，必须等阅读会话解决冲突。
do
    local src = WeChat.new()
    require("source.wechat.context").clear()
    local entered = {}
    fake_client.putProgressAsync = function(_, book_id, opts, cb)
        entered[#entered + 1] = opts
        require("source.wechat.context").reader(book_id, opts.chapter_uid).entered = true
        cb({ ok = true })
    end
    local stats_pushes = {}
    stub("book.stats", function()
        return { push = function(source) stats_pushes[#stats_pushes + 1] = source end }
    end)
    local identity = { source_id = "wechat", stable_id = "bp", chapter_idx = 1 }
    src:onEvent("chapter_changed", {
        identity = identity,
        position = { fraction = 0.1, chapter_idx = 1, chapter_fraction = 0.2 },
    })
    require("support.stubs").flush()
    Assert.len(entered, 0, "开读章节不能在冲突决议前覆盖云端")
    Assert.len(stats_pushes, 1, "开章时顺手补报上一章已落库的时长")

    -- 开书拉云端进度期间挂起 enter，拉取回调之后再发，避免 enter 写的位置吞掉进度冲突。
    local pull_cb
    fake_client.getProgressAsync = function(_, _, cb)
        pull_cb = cb
        return { cancel = function() end }
    end
    require("source.wechat.context").clear()
    entered = {}
    local pulled
    src:getProgressAsync(identity, function(_, err) pulled = err end)
    src:onEvent("chapter_changed", { identity = identity, position = { chapter_idx = 1 } })
    require("support.stubs").flush()
    Assert.len(entered, 0, "拉取未返回前不 enter")
    pull_cb(nil, "offline")
    require("support.stubs").flush()
    Assert.eq(pulled, "offline")
    Assert.len(entered, 0, "拉取失败也不能抢写")

    -- 取消拉取（关书 / 换书）不能吞掉挂起的 enter；回调后再取消也不重复发。
    entered = {}
    local job = src:getProgressAsync(identity, function() error("取消后不回调") end)
    src:onEvent("chapter_changed", { identity = identity, position = { chapter_idx = 1 } })
    require("support.stubs").flush()
    Assert.len(entered, 0)
    job.cancel()
    require("support.stubs").flush()
    Assert.len(entered, 0, "取消不上传位置")
    job.cancel()
    pull_cb(nil, "late")
    require("support.stubs").flush()
    Assert.len(entered, 0, "取消后迟到的回包不上传")
    src:onEvent("chapter_changed", { identity = identity, position = { chapter_idx = 1 } })
    require("support.stubs").flush()
    Assert.len(entered, 0, "之后切章仍不抢写")
    fake_client.putProgressAsync = nil
    fake_client.getProgressAsync = nil
end

-- 拉进度：精确定位拿不到正文（离线）或对不上时退回章级位置，不把整条进度丢掉。
do
    local src = WeChat.new()
    local Toc = require("source.wechat.toc")
    local Position = require("source.wechat.progress")
    local old_index, old_read, old_load, old_localize = Toc.index, Toc.read, Position.loadAsync, Position.localize
    Toc.index = function() return 3 end
    Toc.read = function() return { [3] = { title = "第三章" } } end
    fake_client.getProgressAsync = function(_, _, cb)
        cb({ book = { chapterUid = 33, chapterIdx = 9, chapterOffset = 120, progress = 40 } })
        return { cancel = function() end }
    end
    local identity = { source_id = "wechat", stable_id = "bp", chapter_idx = 1 }

    Position.loadAsync = function(_identity, _chapter, cb) cb(nil, "offline") end
    local pos, err
    src:getProgressAsync(identity, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(pos.chapter_idx, 3, "正文拿不到：退回章级位置")
    Assert.eq(pos.extra.chapter_uid, 33)
    Assert.eq(pos.extra.chapter_offset, 120, "原文偏移保留给 push 复用")

    Position.loadAsync = function(_identity, _chapter, cb) cb("<p>x</p>", "html") end
    Position.localize = function() return nil, "无法定位阅读进度" end
    pos, err = nil, nil
    src:getProgressAsync(identity, function(p, e) pos, err = p, e end)
    Assert.is_nil(err)
    Assert.eq(pos.chapter_idx, 3, "定位失败：退回章级位置")

    Toc.index, Toc.read, Position.loadAsync, Position.localize = old_index, old_read, old_load, old_localize
    fake_client.getProgressAsync = nil
end

-- getDetailAsync：wire 经 mapper 转 Book，并把封面 URL 记进缓存供 coverRequest 用
do
    local src = WeChat.new()
    existing_book = { deleted = 0 }
    existing_progress = { fraction = 0.37 }
    fake_client.bookInfoAsync = function(_, book_id, cb)
        Assert.eq(book_id, "b1")
        cb({ book = { bookId = "b1", title = "详情书", author = "某人",
                      intro = "完整简介", cover = "https://img.weread.qq.com/c.jpg" } })
        return { cancel = function() end }
    end
    local book, err
    src:getDetailAsync(REF, function(b, e) book, err = b, e end)
    Assert.is_nil(err)
    Assert.eq(book.stable_id, "b1")
    Assert.eq(book.title, "详情书")
    Assert.eq(book.intro, "完整简介")
    Assert.eq(book.percent, 37, "详情接口缺进度时必须保留数据库进度")
    Assert.len(remembered_stats_books, 1)
    Assert.eq(remembered_stats_books[1].intro, "完整简介",
        "完整详情必须持久化，不能只活在当前详情页")
    Assert.eq(src:coverRequest(REF).url, "https://img.weread.qq.com/c.jpg")

    -- 空 wire → 明确报错而非返回半个 Book
    fake_client.bookInfoAsync = function(_, _, cb)
        cb({})
        return { cancel = function() end }
    end
    book, err = nil, nil
    src:getDetailAsync(REF, function(b, e) book, err = b, e end)
    Assert.is_nil(book)
    Assert.eq(err, "书籍详情为空")

    fake_client.bookInfoAsync = function(_, _, cb)
        cb(nil, "详情拉取失败")
        return { cancel = function() end }
    end
    book, err = nil, nil
    src:getDetailAsync(REF, function(b, e) book, err = b, e end)
    Assert.is_nil(book)
    Assert.eq(err, "详情拉取失败")
    fake_client.bookInfoAsync = nil
    existing_book = nil
    existing_progress = nil
end

-- openBookAsync：源自己管理联网/进度 UI，成功首参只返回已入库物理路径。
do
    chapter_open.path = "/cache/wechat/b1/2.html"
    chapter_open.err = nil
    local src = WeChat.new()
    local path, err, extra
    src:openBookAsync(REF, { chapter_idx = 2 }, function(...)
        path, err, extra = ...
    end)
    Assert.eq(path, "/cache/wechat/b1/2.html")
    Assert.is_nil(err)
    Assert.is_nil(extra, "源打开回调不得泄露章节上下文")
    Assert.eq(progress_ui.shown, 1)
    Assert.eq(progress_ui.closed, 1)
    Assert.eq(progress_ui.progress[#progress_ui.progress], 4)

    chapter_open.path = nil
    chapter_open.err = "下载失败"
    src:openBookAsync(REF, nil, function(p, e)
        path, err = p, e
    end)
    Assert.is_nil(path)
    Assert.eq(err, "下载失败")
    Assert.eq(progress_ui.shown, 2)
    Assert.eq(progress_ui.closed, 2)

    -- 用户点开的章取不到正文：给临时提示页，不是失败；预取 / 整本缓存不经这里。
    local payload, fetch_err
    chapter_open.ops.fetchContent(REF, { title = "第二章" }, function(p, e) payload, fetch_err = p, e end)
    Assert.is_nil(fetch_err)
    Assert.is_true(payload.temporary)
    Assert.matches(payload.html, "试读")
end

-- putProgressAsync：fraction → percent（0/1 边界、四舍五入、缺进度兜底）
do
    toc_payload["b1"] = [[
        [{"idx":1,"source_idx":2,"uid":"40"},{"idx":2,"source_idx":4,"uid":"41"},
         {"idx":3,"source_idx":7,"uid":"42"}]
    ]]
    local captured
    fake_client.putProgressAsync = function(_, stable_id, opts, cb)
        captured = {
            stable_id = stable_id,
            progress = opts.progress,
            chapter_uid = opts.chapter_uid,
            chapter_idx = opts.chapter_idx,
            chapter_offset = opts.chapter_offset,
            summary = opts.summary,
        }
        cb({ ok = true })
        return { cancel = function() end }
    end
    local src = WeChat.new()

    local function put(pos)
        if pos and not pos.locator and pos.extra and pos.extra.chapter_idx == 0 then
            pos.chapter_fraction = 0
        end
        local ok, err
        src:putProgressAsync(REF, pos, function(v, e) ok, err = v, e end)
        return ok, err
    end

    -- 源私有的 chapter_uid 走 extra；REF 无 chapter_idx，归一后为 0
    local UID = { chapter_uid = 42, chapter_idx = 0, chapter_offset = 12345 }
    Assert.is_true(put({ fraction = 0, extra = UID }))
    Assert.eq(captured.progress, 0)
    Assert.is_true(put({ fraction = 1, extra = UID }))
    Assert.eq(captured.progress, 100)
    Assert.is_true(put({ fraction = 0.5, extra = UID }))
    Assert.eq(captured.progress, 50)
    -- 四舍五入：0.666 → 67
    Assert.is_true(put({ fraction = 0.666, extra = UID }))
    Assert.eq(captured.progress, 67)
    -- clampFraction 兼容 1..100 百分数入参
    Assert.is_true(put({ fraction = 25, extra = UID }))
    Assert.eq(captured.progress, 25)
    -- 缺 chapter_uid 无法上传
    Assert.is_nil(put({}))
    Assert.is_nil(put(nil))
    -- 没有章节的行：未读完 → 永久失败；读完（手动标已读）→ 按末章读完上报
    local perm
    src:putProgressAsync(REF, { fraction = 0.5 }, function(_, _, meta) perm = meta end)
    require("support.stubs").flush()
    Assert.is_true(perm and perm.permanent)
    local done
    src:putProgressAsync(REF, { fraction = 1 }, function(v) done = v end)
    require("support.stubs").flush()
    Assert.is_true(done)
    Assert.eq(captured.chapter_uid, "42")
    Assert.eq(captured.chapter_offset, 16015, "章末取真实原文坐标，不是固定 10000")
    Assert.eq(captured.progress, 100)
    require("source.toc").clear()
    -- stable_id 透传
    Assert.eq(captured.stable_id, "b1")
    -- 仅有 chapter_idx、无 uid 且目录拉取失败时不上传
    fake_client.chapterInfosAsync = function(_, _, cb)
        cb(nil, "目录拉取失败")
        return { cancel = function() end }
    end
    Assert.is_nil(put({ fraction = 0.5, locator = "epubcfi(/6/4)", chapter_idx = 3 }))
    Assert.is_true(put({ fraction = 0.5, extra = UID }))
    Assert.eq(captured.chapter_uid, 42)
    Assert.is_true(put({
        fraction = 0.5, chapter_idx = 3, chapter_fraction = 0.25, chapter_title = "序章",
        locator = "/html/body/p/text().12345",
        extra = { chapter_uid = 42, chapter_idx = 3, chapter_offset = 1 },
    }))
    Assert.eq(captured.chapter_idx, 7, "上传必须使用微信原始 chapterIdx")
    Assert.eq(captured.chapter_offset, 12360, "必须按 XPointer 计算，不能复用旧 extra 偏移")
    Assert.eq(captured.summary, string.rep("文正", 15), "摘要必须是当前位置正文，不是章名")
    -- extra 记的是别的章：不复用旧 uid，回落到目录解析（此处目录拉取失败 → 不上传）
    Assert.is_nil(put({ fraction = 0.5, chapter_idx = 7, extra = { chapter_uid = 42, chapter_idx = 3 } }))
    -- 目标章不在目录里：不能回退成当前打开章的 uid，否则进度报到错误章节
    require("support.stubs").flush()
    captured = nil
    local in_chapter = setmetatable({ chapter_idx = 1 }, { __index = REF })
    local ok, err
    src:putProgressAsync(in_chapter, { fraction = 0.5, chapter_idx = 9 }, function(v, e) ok, err = v, e end)
    require("support.stubs").flush()
    Assert.is_nil(ok)
    Assert.eq(err, "缺少章节信息")
    Assert.is_nil(captured, "不得用当前章 uid 40 上报")
    -- locator 对不上章节正文：永久失败（否则脏同步每轮白撞）
    local map_ok, map_err, map_meta
    src:putProgressAsync(REF, {
        fraction = 0.5,
        locator = "/html/body/div/text().0",
        extra = UID,
    }, function(v, e, meta) map_ok, map_err, map_meta = v, e, meta end)
    Assert.is_nil(map_ok)
    Assert.is_nil(captured)
    Assert.is_true(map_meta and map_meta.permanent)
    Assert.eq(map_err, "reading position not found in chapter")
    toc_payload["b1"] = nil
    require("source.wechat.toc").clear()
end

-- putProgressAsync：失败时错误原样透传；client 的 permanent 元信息也要透传
do
    fake_client.putProgressAsync = function(_, _, _, cb)
        cb(nil, "写入失败")
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local ok, err
    src:putProgressAsync(REF, {
        fraction = 0.5, chapter_fraction = 0, extra = { chapter_uid = 42, chapter_idx = 0 },
    }, function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "写入失败")

    fake_client.putProgressAsync = function(_, _, _, cb)
        cb(nil, "上报响应异常", { permanent = true })
        return { cancel = function() end }
    end
    local soft_ok, soft_err, soft_meta
    src:putProgressAsync(REF, {
        fraction = 0.5, chapter_fraction = 0, extra = { chapter_uid = 42, chapter_idx = 0 },
    }, function(v, e, m) soft_ok, soft_err, soft_meta = v, e, m end)
    Assert.is_nil(soft_ok)
    Assert.eq(soft_err, "上报响应异常")
    Assert.is_true(soft_meta and soft_meta.permanent)
end

-- getProgressAsync：percent → fraction（边界 0/100、缺进度兜底、已读完抬满）
do
    local wire
    fake_client.getProgressAsync = function(_, _, cb)
        cb(wire)
        return { cancel = function() end }
    end
    local src = WeChat.new()

    local function get()
        local pos, err
        src:getProgressAsync(REF, function(p, e) pos, err = p, e end)
        return pos, err
    end

    wire = { percent = 50 }
    local pos = get()
    Assert.eq(pos.fraction, 0.5)
    Assert.is_nil(pos.chapter_idx)

    wire = { percent = 0 }
    Assert.eq(get().fraction, 0)

    wire = { percent = 100 }
    Assert.eq(get().fraction, 1)

    -- 缺进度兜底：wire 无进度字段按 0
    wire = {}
    Assert.eq(get().fraction, 0)

    -- 已读完标记把进度抬到 100%
    wire = { percent = 30, finishReading = 1 }
    Assert.eq(get().fraction, 1)

    -- getProgress 真实 wire：{ bookId, book: { chapterUid, progress, ... } }
    wire = { bookId = "42", book = { chapterUid = "99", chapterIdx = 7, progress = 77, chapterOffset = 5000 } }
    pos = get()
    Assert.eq(pos.fraction, 0.77)
    Assert.eq(pos.chapter_idx, 7)
    Assert.eq(pos.extra.chapter_offset, 5000)
    Assert.eq(pos.locator, "/html/body/p/text().4985")

    -- 自带 chapter_idx 时直接回调，不再拉目录
    wire = { percent = 10, chapterIdx = 7, chapterUid = "99" }
    pos = get()
    Assert.eq(pos.chapter_idx, 7)
    Assert.eq(pos.fraction, 0.1)
end

-- getProgressAsync：网络失败错误透传；取消后迟到的回调被丢弃
do
    fake_client.getProgressAsync = function(_, _, cb)
        cb(nil, "拉取失败")
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local pos, err
    src:getProgressAsync(REF, function(p, e) pos, err = p, e end)
    Assert.is_nil(pos)
    Assert.eq(err, "拉取失败")

    local pending
    fake_client.getProgressAsync = function(_, _, cb)
        pending = cb
        return { cancel = function() end }
    end
    local fired = false
    local handle = src:getProgressAsync(REF, function() fired = true end)
    handle.cancel()
    pending({ percent = 50 })
    Assert.is_false(fired)
end

-- 封面缓存：syncBooksAsync 记住 http(s) 封面，非法 URL / 无封面不缓存
do
    fake_client.shelfSyncAsync = function(_, cb)
        cb({
            books = {
                { book = { bookId = "b1", title = "书一", cover = "https://cdn.example.com/a.jpg" } },
                { book = { bookId = "b2", title = "书二", cover = "//cdn.example.com/b.jpg" } },
                { book = { bookId = "b3", title = "书三" } },
            },
        })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local result
    src:syncBooksAsync(nil, function(r) result = r end)
    require("support.stubs").flush()
    Assert.not_nil(result)

    -- 合法 http(s) 封面入缓存，coverRequest 带回会话头
    local req = src:coverRequest({ source_id = "wechat", stable_id = "b1" })
    Assert.not_nil(req)
    Assert.eq(req.url, "https://cdn.example.com/a.jpg")
    Assert.eq(req.headers.Cookie, "wr_skey=stub")

    -- 新源实例没有内存缓存，必须从 Book/数据库恢复封面。
    local fresh = WeChat.new()
    local direct = fresh:coverRequest({
        source_id = "wechat", stable_id = "b1", cover = "https://cdn.example.com/a.jpg",
    })
    Assert.eq(direct.url, "https://cdn.example.com/a.jpg")
    Assert.eq(direct.headers.Cookie, "wr_skey=stub")

    -- 非 http(s) 前缀的封面不入缓存
    local req2, err2 = src:coverRequest({ source_id = "wechat", stable_id = "b2" })
    Assert.is_nil(req2)
    Assert.eq(err2, "无封面")

    -- 无封面字段的书籍
    local req3 = src:coverRequest({ source_id = "wechat", stable_id = "b3" })
    Assert.is_nil(req3)

    -- 重复列表刷新封面缓存（后写覆盖先写）
    fake_client.shelfSyncAsync = function(_, cb)
        cb({
            books = {
                { book = { bookId = "b1", title = "书一", cover = "https://cdn.example.com/a2.jpg" } },
            },
        })
        return { cancel = function() end }
    end
    src:syncBooksAsync(nil, function() end)
    require("support.stubs").flush()
    Assert.eq(src:coverRequest({ source_id = "wechat", stable_id = "b1" }).url,
        "https://cdn.example.com/a2.jpg")

    -- close 清空实例的封面缓存
    src:close()
    local req4 = src:coverRequest({ source_id = "wechat", stable_id = "b1" })
    Assert.is_nil(req4)
end

-- syncBooksAsync：本地新加架经 addToShelf 上行，SyncResult.pushed 填实；
-- 已同步但云端已移除的书不加回。
do
    local added = {}
    local shelf_calls = 0
    fake_client.shelfSyncAsync = function(_, cb)
        shelf_calls = shelf_calls + 1
        cb({
            books = {
                { book = { bookId = "remote1", title = "远端书" } },
            },
        })
        return { cancel = function() end }
    end
    fake_client.addToShelfAsync = function(_, bookId, cb)
        added[#added + 1] = bookId
        cb({ ok = true })
        return { cancel = function() end }
    end
    remembered_stats_books.local_library = { "remote1", "local_only", "removed_on_phone" }
    remembered_stats_books.pending_adds = { "local_only" }
    local src = WeChat.new()
    local result
    src:syncBooksAsync(nil, function(r) result = r end)
    require("support.stubs").flush()
    Assert.not_nil(result)
    Assert.eq(result.pushed, 1)
    Assert.eq(#added, 1)
    Assert.eq(added[1], "local_only")
    Assert.eq(shelf_calls, 2, "有上行后应再拉一次书架再 reconcile")
    remembered_stats_books.local_library = nil
    remembered_stats_books.pending_adds = nil
end

-- pullNotesAsync：微信原始 chapterIdx 必须按 uid 映射成本地过滤后的章节序号。
do
    toc_payload["bpull"] = '[{"idx":5,"source_idx":6,"uid":"41"}]'
    fake_client.bookmarkListAsync = function(_, _, cb)
        cb({
            updated = {
                {
                    chapterUid = "41", chapterIdx = 6, bookmarkId = "bm1",
                    type = 1, range = "1-3", markText = "划线", createTime = 1,
                },
            },
            chapters = { { chapterUid = "41", chapterIdx = 6 } },
        })
        return { cancel = function() end }
    end
    fake_client.myReviewsAsync = function(_, _, cb)
        cb({ reviews = {} })
        return { cancel = function() end }
    end
    local annotations
    WeChat.new():pullNotesAsync({
        source_id = "wechat", stable_id = "bpull", chapter_idx = 5,
    }, function(value) annotations = value end)
    require("support.stubs").flush()
    Assert.eq(annotations[1].chapter_idx, 5)

    -- 目录缓存没有、也拉不到：章节号留空，绝不回退成原始序号 6（本地第 6 章是别的章）。
    toc_payload["bpull"] = nil
    require("source.toc").clear()
    fake_client.chapterInfosAsync = function(_, _, cb)
        cb(nil, "目录拉取失败")
        return { cancel = function() end }
    end
    annotations = nil
    WeChat.new():pullNotesAsync({
        source_id = "wechat", stable_id = "bpull", chapter_idx = 5,
    }, function(value) annotations = value end)
    require("support.stubs").flush()
    Assert.len(annotations, 1)
    Assert.is_nil(annotations[1].chapter_idx)
end

-- pushNotesAsync：划线与想法两段队列必须串起来
do
    chapter_fetches = 0
    local NOTE_REF = {
        source_id = "wechat",
        stable_id = "bpush",
        chapter_idx = 2,
        book = { title = "微信书" },
    }
    require("source.wechat.context").rememberBookVersion("bpush", 7)
    -- chapter_uid 只从目录缓存解析，预置一条免去拉取
    toc_payload["bpush"] = '[{"idx":1,"source_idx":3,"uid":"8"},{"idx":2,"source_idx":6,"uid":"9"}]'
    local calls
    local remote_bookmarks = {
        {
            chapterUid = "9", chapterIdx = 6, bookmarkId = "bm1",
            type = 1, range = "3-6", markText = "旧划线",
        },
    }
    chapter_range_html = "<p>旧划线</p><p>新划线</p><p>补偿划线</p>"
        .. "<p>部分一</p><p>部分二</p>"
    local Paths = require("utils.paths")
    local chapter_path = Paths.chapterPath("bpush", 2, "wechat")
    assert(Paths.ensureDir(Paths.bookWorkDir("bpush", "wechat")))
    -- 沙箱跨运行保留：清掉上次留下的 range 原文缓存，首个定位必走一次拉取并回填缓存
    os.remove(Paths.bookWorkDir("bpush", "wechat") .. "/2.position.json")
    local chapter_file = assert(io.open(chapter_path, "wb"))
    chapter_file:write("<html><body><h1>微信书</h1><p>旧划线</p><p>新划线</p>"
        .. "<p>补偿划线</p><p>部分一</p><p>部分二</p></body></html>")
    chapter_file:close()
    local omit_next_id = false
    local fail_text
    local bookmark_ids = {
        ["新划线"] = "bm-new",
        ["补偿划线"] = "bm-postflight",
        ["部分一"] = "bm-part1",
        ["部分二"] = "bm-part2",
    }
    fake_client.bookmarkListAsync = function(_, _, cb)
        cb({ updated = remote_bookmarks })
        return { cancel = function() end }
    end
    fake_client.myReviewsAsync = function(_, _, cb)
        cb({ reviews = { { review = { reviewId = "rv1" } } } })
        return { cancel = function() end }
    end
    fake_client.addBookmarkAsync = function(_, _, _, body, cb)
        local text = body.markText
        local remote_id = bookmark_ids[text]
        calls[#calls + 1] = {
            api = "addBookmark", range = body.range, chapter_idx = body.chapterIdx,
        }
        if text == fail_text then
            fail_text = nil
            cb(nil, "timeout")
            return { cancel = function() end }
        end
        remote_bookmarks[#remote_bookmarks + 1] = {
            chapterUid = "9", chapterIdx = 6, bookmarkId = remote_id,
            type = 1, range = body.range, markText = text,
        }
        if omit_next_id then
            omit_next_id = false
            cb({ succ = 1 })
        else
            cb({ bookmarkId = remote_id })
        end
        return { cancel = function() end }
    end
    fake_client.addReviewAsync = function(_, body, cb)
        calls[#calls + 1] = { api = "addReview", content = body.content, range = body.range }
        cb({ reviewId = "rv-new" })
        return { cancel = function() end }
    end
    fake_client.editReviewAsync = function(_, body, cb)
        calls[#calls + 1] = {
            api = "editReview", content = body.content, review_id = body.reviewId,
            book_id = body.bookId, chapter_uid = body.chapterUid,
            range = body.range, abstract = body.abstract,
        }
        cb({ succ = 1 })
        return { cancel = function() end }
    end
    fake_client.deleteReviewAsync = function(_, review_id, cb)
        calls[#calls + 1] = { api = "deleteReview", review_id = review_id }
        cb({ succ = 1 })
        return { cancel = function() end }
    end
    fake_client.removeBookmarkAsync = function(_, bookmark_id, cb)
        calls[#calls + 1] = { api = "removeBookmark", bookmark_id = bookmark_id }
        cb({ succ = 1 })
        return { cancel = function() end }
    end
    fake_client.updateBookmarkAsync = function(_, body, cb)
        calls[#calls + 1] = {
            api = "updateBookmark", bookmark_id = body.bookmarkId, color_style = body.colorStyle,
        }
        cb({ succ = 1 })
        return { cancel = function() end }
    end

    local src = WeChat.new()
    local function push(annotations)
        calls = {}
        local ok, err
        src:pushNotesAsync(NOTE_REF, annotations, function(v, e) ok, err = v, e end)
        require("support.stubs").flush()
        return ok, err
    end

    -- 在已有划线上写想法：无新划线可传，直接走 useredit
    local ok, err = push({
        {
            drawer = "lighten", text = "旧划线", wr_range = "0-3",
            wr_bookmark_id = "bm1", wr_review_id = "rv1", note = "改过的想法",
            wr_update_review = true,
        },
    })
    Assert.is_true(ok, "editReview 未完成: " .. tostring(err))
    Assert.is_nil(err)
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "editReview")
    Assert.eq(calls[1].review_id, "rv1")
    Assert.eq(calls[1].content, "改过的想法")
    Assert.eq(calls[1].book_id, "bpush")
    Assert.eq(calls[1].chapter_uid, 9)
    Assert.eq(calls[1].abstract, "旧划线")
    Assert.eq(chapter_fetches, 0)

    -- 想法列表只拿到一页（hasMore）：不在这页的 review id 不能当云端已删清掉，
    -- 否则会走 addReview 在云端重建一条重复想法。
    local real_my_reviews = fake_client.myReviewsAsync
    fake_client.myReviewsAsync = function(_, _, cb)
        cb({ reviews = { { review = { reviewId = "rv1" } } }, hasMore = 1, totalCount = 101 })
        return { cancel = function() end }
    end
    local far = {
        drawer = "lighten", text = "旧划线", wr_range = "0-3",
        wr_bookmark_id = "bm1", wr_review_id = "rv-far", note = "第101条想法",
        wr_update_review = true,
    }
    ok, err = push({ far })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "editReview")
    Assert.eq(calls[1].review_id, "rv-far")

    -- 全量列表里确实没有：视为云端已删，按新想法重建（原有语义）。
    fake_client.myReviewsAsync = function(_, _, cb)
        cb({ reviews = { { review = { reviewId = "rv1" } } }, hasMore = 0, totalCount = 1 })
        return { cancel = function() end }
    end
    far.wr_review_id, far.wr_update_review = "rv-far", true
    ok = push({ far })
    Assert.is_true(ok)
    Assert.eq(calls[1].api, "addReview")
    fake_client.myReviewsAsync = real_my_reviews

    -- 已有划线但还没有 review：走 add
    ok = push({
        { drawer = "lighten", text = "旧划线", wr_range = "0-3", wr_bookmark_id = "bm1", note = "新想法" },
    })
    Assert.is_true(ok)
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "addReview")
    Assert.eq(calls[1].content, "新想法")

    -- 删除整条原生笔记：远端 review 与 bookmark 都要删除，墓碑随后移除。
    local deleted = {
        wr_deleted = true, wr_bookmark_id = "bm1", wr_review_id = "rv1",
    }
    ok, err = push({ deleted })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 2)
    Assert.eq(calls[1].api, "deleteReview")
    Assert.eq(calls[2].api, "removeBookmark")

    -- 只清空 note：删除 review，但保留底层划线。
    local cleared = {
        datetime = "2026-01-01", drawer = "lighten", text = "旧划线",
        wr_range = "0-3", wr_bookmark_id = "bm1", wr_review_id = "rv1",
        wr_delete_review = true,
    }
    ok, err = push({ cleared })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "deleteReview")
    Assert.eq(cleared.wr_bookmark_id, "bm1")
    Assert.is_nil(cleared.wr_review_id)

    -- 本地修改划线颜色走 updateBookmark，不得伪造新划线。
    local recolored = {
        datetime = "2026-01-01", drawer = "lighten", color = "green", text = "旧划线",
        wr_range = "0-3", wr_bookmark_id = "bm1", wr_update_bookmark = true,
    }
    ok, err = push({ recolored })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "updateBookmark")
    Assert.eq(calls[1].color_style, 2)
    Assert.is_nil(recolored.wr_update_bookmark)

    -- KOReader 原生 note 直接映射微信想法，不能先制造一条远端高亮。
    local fresh = { drawer = "lighten", text = "新划线", wr_range = "4-9", note = "随手记" }
    ok, err = push({ fresh })
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "addReview")
    Assert.eq(calls[1].content, "随手记")
    Assert.is_nil(fresh.wr_bookmark_id)
    Assert.eq(fresh.wr_review_id, "rv-new")
    Assert.eq(chapter_fetches, 1)

    -- 前面已有远端笔记时，仍必须扫描并上传后面的本地新笔记。
    local later = { drawer = "lighten", text = "部分一", note = "后面的新笔记" }
    ok, err = push({
        {
            drawer = "lighten", text = "旧划线", note = "没修改",
            wr_range = "0-3", wr_bookmark_id = "bm1", wr_review_id = "rv1",
        },
        later,
    })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "addReview")
    Assert.eq(calls[1].content, "后面的新笔记")
    Assert.eq(later.wr_review_id, "rv-new")

    -- addBookmark 回包缺 id 时由一次 postflight 找回，不能把未确认提交误判成功。
    omit_next_id = true
    local recovered = { drawer = "lighten", text = "补偿划线" }
    ok, err = push({ recovered })
    Assert.is_true(ok, tostring(err))
    Assert.eq(recovered.wr_bookmark_id, "bm-postflight")
    -- 后续定位全部命中首轮回填的 range 原文缓存，不再重拉整章
    Assert.eq(chapter_fetches, 1)

    -- 批次后半超时：下轮 preflight 必须认回前半成功项，只补传失败项。
    fail_text = "部分一"
    ok = push({
        { drawer = "lighten", text = "部分一" },
        { drawer = "lighten", text = "部分二" },
    })
    Assert.is_nil(ok)
    local retry_first = { drawer = "lighten", text = "部分一" }
    local retry_second = { drawer = "lighten", text = "部分二" }
    ok, err = push({ retry_first, retry_second })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(retry_first.wr_bookmark_id, "bm-part1")
    Assert.eq(retry_second.wr_bookmark_id, "bm-part2")

    -- 章内定位不到的划线只跳过自己：不能让一条坏数据卡住整章，每次重试都停在它身上。
    local ghost = { drawer = "lighten", text = "正文里没有这句" }
    local located = { drawer = "lighten", text = "新划线" }
    ok, err = push({ ghost, located })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "addBookmark")
    Assert.eq(located.wr_bookmark_id, "bm-new")
    Assert.is_nil(ghost.wr_bookmark_id)

    -- 带想法的划线在远端已被删：预检清掉 bookmark id 后仍要把想法推上去，不能静默成功。
    local orphan = {
        drawer = "lighten", text = "新划线", wr_range = "0-3",
        wr_bookmark_id = "bm-gone", note = "孤儿想法",
    }
    ok, err = push({ orphan })
    Assert.is_true(ok, tostring(err))
    Assert.eq(#calls, 1)
    Assert.eq(calls[1].api, "addReview")
    Assert.eq(calls[1].content, "孤儿想法")
    Assert.eq(orphan.wr_review_id, "rv-new")

    -- 无划线也无想法：不发请求
    ok = push({ { drawer = "lighten", text = "旧划线", wr_bookmark_id = "bm1", wr_range = "0-3" } })
    Assert.is_true(ok)
    Assert.eq(#calls, 0)
    os.remove(chapter_path)
end

-- 长按删除：本地先标删，已连网时顺手入队推脏；推脏的书架域推云端真删并撕墓碑
do
    remembered_stats_books.marked_deleted, remembered_stats_books.removed = nil, nil
    local removed
    fake_client.removeFromShelfAsync = function(_, bookId, cb)
        removed = bookId
        cb({ ok = true })
        return { cancel = function() end }
    end
    local enqueued = {}
    package.loaded["workers.tasks"] = { enqueue = function(spec) enqueued[#enqueued + 1] = spec.key; return spec end }
    local src = WeChat.new()
    local ok
    src:deleteBookAsync({ source_id = "wechat", stable_id = "del1" }, function(success)
        ok = success
    end)
    require("support.stubs").flush()
    Assert.is_true(ok)
    Assert.eq(remembered_stats_books.marked_deleted.stable_id, "del1")
    Assert.eq(enqueued[1], "dirty\0wechat")
    src:syncBooksAsync({ dirty_only = true }, function() end)
    require("support.stubs").flush()
    Assert.eq(removed, "del1")
    Assert.eq(remembered_stats_books.removed.stable_id, "del1")
    package.loaded["workers.tasks"] = nil
end

-- 段评：开关读源配置；按目录解析本章 chapter_uid，章节 HTML 读本地文件定位。
do
    toc_payload["b1"] = [[ [{"idx":1,"source_idx":2,"uid":"40"}] ]]
    local Settings = require("utils.settings")
    local src = WeChat.new()
    Assert.is_false(src:paragraphReviewsEnabled())
    local getSource = Settings.getSource
    Settings.getSource = function() return { show_paragraph_reviews = true } end
    Assert.is_true(src:paragraphReviewsEnabled())
    Settings.getSource = getSource

    local calls = {}
    fake_client.underlinesAsync = function(_self, book_id, uid, cb)
        calls[#calls + 1] = { book_id, uid }
        cb({ underlines = { { range = "1-5" } } })
        return { cancel = function() end }
    end
    fake_client.readReviewsAsync = function(_self, book_id, uid, reviews, cb)
        calls[#calls + 1] = { book_id, uid, reviews }
        cb({ reviews = { {
            range = "1-5", totalCount = 3, maxIdx = 1, hasMore = 0,
            pageReviews = { { review = { abstract = "甲乙丙丁。", author = { name = "a" }, content = "c" } } },
        } } })
        return { cancel = function() end }
    end
    local identity = setmetatable({ chapter_idx = 1 }, { __index = REF })
    local hotspots
    src:paragraphHotspotsAsync(identity, function(value) hotspots = value end)
    require("support.stubs").flush()
    Assert.eq(calls[1][1], "b1")
    Assert.eq(calls[1][2], "40")
    Assert.len(hotspots, 1)
    local spots = src:locateHotspots(hotspots, "<html><body><p>甲乙丙丁。</p></body></html>")
    Assert.len(spots, 1)
    Assert.eq(spots[1].pos0, "/html/body/p/text().0")

    local page
    src:paragraphReviewPageAsync(identity, "1-5", 0, function(value) page = value end)
    require("support.stubs").flush()
    Assert.eq(calls[3][3][1].count, 30)
    Assert.eq(page.total, 3)
    Assert.is_false(page.more)

    -- 本章不在目录且目录拉不到：报错，不发段评请求。
    fake_client.chapterInfosAsync = function(_self, _book_id, cb)
        cb(nil, "目录拉取失败")
        return { cancel = function() end }
    end
    local err
    src:paragraphReviewPageAsync(setmetatable({ chapter_idx = 9 }, { __index = REF }), "1-5", 0,
        function(_page, e) err = e end)
    require("support.stubs").flush()
    Assert.not_nil(err)
    Assert.len(calls, 3)
    toc_payload["b1"] = nil
    require("source.wechat.toc").clear()

    -- 书名搜索：只留带 bookId 的书目。
    local keyword
    fake_client.searchAsync = function(_self, word, cb)
        keyword = word
        cb({ books = {
            { type = 0, bookInfo = { bookId = 834464, title = "活着", author = "余华", publisher = "作家" } },
            { type = 3, mpInfo = { title = "公众号" } },
        } })
        return { cancel = function() end }
    end
    local found
    src:searchBooksAsync("活着", function(books) found = books end)
    Assert.eq(keyword, "活着")
    Assert.len(found, 1)
    Assert.eq(found[1].book_id, "834464")
    Assert.eq(found[1].author, "余华")
end

-- pushNotesAsync 中途取消：在途请求被取消，迟到回包不回调、不再发后续请求。
do
    toc_payload["bcancel"] = '[{"idx":1,"source_idx":1,"uid":"7"}]'
    local pending, cancelled, requests = nil, 0, 0
    fake_client.bookmarkListAsync = function(_, _, cb)
        requests = requests + 1
        pending = cb
        return { cancel = function() cancelled = cancelled + 1 end }
    end
    fake_client.myReviewsAsync = function()
        requests = requests + 1
        error("取消后不应继续请求")
    end
    local src = WeChat.new()
    local called = false
    local job = src:pushNotesAsync(
        { source_id = "wechat", stable_id = "bcancel", chapter_idx = 1 },
        { { drawer = "lighten", text = "甲" } },
        function() called = true end
    )
    require("support.stubs").flush()
    Assert.eq(requests, 1, "先发预检")
    job.cancel()
    Assert.eq(cancelled, 1, "取消在途的预检请求")
    pending({ updated = {} })
    require("support.stubs").flush()
    Assert.is_false(called, "取消后不回调")
    Assert.eq(requests, 1)

    -- 无事可做直接成功，不发请求。
    local ok
    Assert.is_nil(src:pushNotesAsync({ source_id = "wechat", stable_id = "bcancel", chapter_idx = 1 },
        { { drawer = "lighten", text = "甲", wr_bookmark_id = "b", wr_range = "0-1" } },
        function(v) ok = v end))
    Assert.is_true(ok)
    Assert.eq(requests, 1)
    toc_payload["bcancel"] = nil
    fake_client.bookmarkListAsync = nil
    fake_client.myReviewsAsync = nil
end

-- 增量拉书架：有游标时只拉 id 增量，变更补详情、其余用本地行拼快照，不走全量
do
    remembered_stats_books.local_library = { "a", "b", "gone" }
    remembered_stats_books.pending_adds = {}
    remembered_stats_books.local_rows = {
        a = { source_id = "wechat", stable_id = "a", title = "甲", deleted = 0 },
        b = { source_id = "wechat", stable_id = "b", title = "乙旧", category = "我的分组", deleted = 0 },
        gone = { source_id = "wechat", stable_id = "gone", title = "删", deleted = 0 },
    }
    local ids_req, books_req, full_called = nil, nil, false
    fake_client.shelfSyncIdsAsync = function(_, synckey, count, cb)
        ids_req = { synckey = synckey, count = count }
        cb({ synckey = 101, bookCount = 3, removed = { "gone" },
            bookIds = { { bookId = "b", type = 0 }, { bookId = "c", type = 0 } },
            archive = {}, albumRemoved = {}, removedArchive = {} })
        return { cancel = function() end }
    end
    fake_client.shelfSyncBooksAsync = function(_, ids, cb)
        books_req = ids
        cb({ books = { { bookId = "b", title = "乙新", category = "玄幻" }, { bookId = "c", title = "丙" } },
            bookProgress = { { bookId = "c", progress = 50 } }, albums = {}, emptyInfoIds = {} })
        return { cancel = function() end }
    end
    fake_client.shelfSyncAsync = function(_, cb)
        full_called = true
        cb({ books = {} })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    src.cfg.wr_vid = "v1"
    src.cfg.shelf_cursor = { vid = "v1", synckey = 100 }
    local result
    src:syncBooksAsync(nil, function(r) result = r end)
    require("support.stubs").flush()
    Assert.not_nil(result)
    Assert.is_false(full_called, "增量对得齐时不走全量")
    Assert.eq(ids_req.synckey, 100)
    Assert.eq(ids_req.count, 3)
    Assert.len(books_req, 2)
    local snap = {}
    for _idx, b in ipairs(remembered_stats_books.last_snapshot) do snap[b.stable_id] = b end
    Assert.eq(snap.a.title, "甲")
    Assert.eq(snap.b.title, "乙新")
    Assert.eq(snap.b.category, "我的分组", "分组无变更时保留本地分组名")
    Assert.is_nil(snap.gone, "removed 的书不进快照")
    Assert.not_nil(snap.c, "新增的书经 syncbook 补进快照")
    Assert.eq(src.cfg.shelf_cursor.synckey, 101, "reconcile 成功后推进游标")
    fake_client.shelfSyncIdsAsync, fake_client.shelfSyncBooksAsync = nil, nil
    remembered_stats_books.local_library, remembered_stats_books.local_rows = nil, nil
    remembered_stats_books.last_snapshot = nil
end

-- 增量对不齐（数量对不上）回退全量，全量成功后游标取全量回包的 synckey
do
    remembered_stats_books.local_library = { "a" }
    remembered_stats_books.pending_adds = {}
    remembered_stats_books.local_rows = {
        a = { source_id = "wechat", stable_id = "a", title = "甲", deleted = 0 },
    }
    local full_called = false
    fake_client.shelfSyncIdsAsync = function(_, _synckey, _count, cb)
        cb({ synckey = 102, bookCount = 99, removed = {}, bookIds = {},
            archive = {}, albumRemoved = {}, removedArchive = {} })
        return { cancel = function() end }
    end
    fake_client.shelfSyncAsync = function(_, cb)
        full_called = true
        cb({ synckey = 555, books = { { bookId = "a", title = "甲" } } })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    src.cfg.wr_vid = "v1"
    src.cfg.shelf_cursor = { vid = "v1", synckey = 100 }
    local result
    src:syncBooksAsync(nil, function(r) result = r end)
    require("support.stubs").flush()
    Assert.not_nil(result)
    Assert.is_true(full_called, "数量对不齐应回退全量")
    Assert.eq(src.cfg.shelf_cursor.synckey, 555)
    fake_client.shelfSyncIdsAsync = nil
    remembered_stats_books.local_library, remembered_stats_books.local_rows = nil, nil
    remembered_stats_books.last_snapshot = nil
end

-- 书城浏览：目录树与榜单书每次都调 client，源不留实例缓存（新鲜度归 client 的 http 缓存）
do
    local cat_calls, book_calls = 0, 0
    fake_client.storeCategoriesAsync = function(_, cb)
        cat_calls = cat_calls + 1
        cb({ data = { { categories = {
            { CategoryId = "rising", title = "飙升榜", ranklist = 1, sublist = {} },
        } } } })
        return { cancel = function() end }
    end
    fake_client.storeBooksAsync = function(_, _node, _offset, _is_rank, cb)
        book_calls = book_calls + 1
        cb({ books = {}, hasMore = 0 })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local res
    src:browseAsync({}, function(r) res = r end)
    Assert.eq(cat_calls, 1)
    Assert.eq(res.groups[1].chips[1].id, "rising")
    src:browseAsync({}, function(r) res = r end)
    Assert.eq(cat_calls, 2, "源不缓存目录树，每次浏览都调 client")
    Assert.eq(book_calls, 2, "榜单书每次调 client")

    -- 目录同步回完、榜单请求在途：取消必须打到在途请求，外层赋值不能覆盖它。
    local cancelled = 0
    fake_client.storeBooksAsync = function()
        return { cancel = function() cancelled = cancelled + 1 end }
    end
    local browse_handle = src:browseAsync({}, function() error("请求尚未完成") end)
    browse_handle.cancel()
    Assert.eq(cancelled, 1)
    fake_client.storeCategoriesAsync, fake_client.storeBooksAsync = nil, nil
end

-- 还原打桩，避免影响本文件之后的其它用例
for name, factory in pairs(saved_preload) do
    package.preload[name] = factory
    package.loaded[name] = nil
end
package.loaded["source.wechat"] = nil
