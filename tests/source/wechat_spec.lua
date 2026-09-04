--[[--
source.wechat 门面离线用例：进度 fraction↔percent 换算、chapter_uid 目录匹配、封面缓存。

client/auth/chapter/settings 用 package.preload 打桩；mapper 用真实实现。

@module tests.wechat_spec
--]]

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
local chapter_range_html
local chapter_fetches = 0
local progress_ui = { shown = 0, closed = 0, progress = {} }

-- 目录缓存 payload 要真解码才能取出 chapter_uid
stub("json", function()
    return {
        decode = require("support.json_stub").decode,
        encode = require("support.json_stub").encode,
    }
end)

-- 目录缓存：按 stable_id 供给 payload，未登记的书一律未命中
local toc_payload = {}
stub("db.book", function()
    return {
        getToc = function(_, stable_id) return toc_payload[stable_id] end,
        setToc = function(_, stable_id, payload)
            toc_payload[stable_id] = payload
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
stub("source.wechat.client", function()
    return {
        new = function() return fake_client end,
    }
end)
stub("source.wechat.chapter", function()
    return {
        ensurePsvtsAsync = function(_, _, cb)
            cb(true)
            return { cancel = function() end }
        end,
        fetchHtmlAsync = function(_, _, cb)
            chapter_fetches = chapter_fetches + 1
            cb(chapter_range_html, nil, chapter_range_html)
            return { cancel = function() end }
        end,
    }
end)
stub("ui/network/manager", function()
    return { runWhenOnline = function(_, fn) fn() end }
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
            cb(chapter_open.path, chapter_open.err)
            return { cancel = function() chapter_open.cancelled = true end }
        end,
    }
end)
stub("book.store", function()
    return {
        reconcile = function(_, books)
            return { pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false }
        end,
    }
end)

package.loaded["source.wechat"] = nil
local WeChat = require("source.wechat")

local REF = { source_id = "wechat", stable_id = "b1", book = { title = "微信书" } }

do
    local caps = WeChat.new():capabilities()
    Assert.is_false(caps.scrape)
    Assert.is_false(caps.edit)
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
        elseif mode == "annually" and base_time == 1_735_689_600 then
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
    local result
    WeChat.new():pullStatsAsync(function(value) result = value end)
    Assert.eq(requests[1][1], "overall")
    Assert.eq(requests[2][1], "annually")
    Assert.eq(requests[3][1], "annually")
    Assert.eq(requests[4][1], "monthly")
    Assert.eq(requests[4][2], 1_735_689_600)
    Assert.not_nil(requests[2][2])
    Assert.not_nil(requests[3][2])
    Assert.eq(result.replace.mode, "ranges")
    Assert.len(result.replace.ranges, 5)
    local total, monthly_day
    for _, row in ipairs(result.rows) do
        if row.record_type == "total" then total = row.duration end
        if row.stable_id == "__wr:day:1735776000" then monthly_day = row.duration end
    end
    Assert.eq(total, 7200)
    Assert.eq(monthly_day, 900)
    fake_client.readStatsAsync = nil
end

-- pushStatsAsync：无章节坐标的行无处可报，直接成功而非空转失败。
do
    local src = WeChat.new()
    local ok, err
    src:pushStatsAsync({ { stable_id = "b1", duration = 10 } }, function(data, e)
        ok, err = data, e
    end)
    Assert.not_nil(ok)
    Assert.is_nil(err)
end

-- pushStatsAsync 逐章上报中途失败：只确认已报出去的章。
-- 若把全部行一起确认就会丢时长，若一条都不确认则下次重试把已报的章再报一遍（微信侧翻倍）。
do
    local src = WeChat.new()
    toc_payload["bp"] = require("support.json_stub").encode({
        { idx = 1, source_idx = 3, uid = "u1", title = "一" },
        { idx = 2, source_idx = 5, uid = "u2", title = "二" },
    })
    local reported = 0
    local reported_payloads = {}
    fake_client.reportReadAsync = function(_, raw, _, cb)
        reported = reported + 1
        reported_payloads[#reported_payloads + 1] = require("json").decode(raw)
        if reported == 1 then
            cb({ ok = true })
        else
            cb(nil, "boom")
        end
        return { cancel = function() end }
    end
    local data, err
    src:pushStatsAsync({
        { id = 11, stable_id = "bp", chapter_idx = 1, duration = 10 },
        { id = 12, stable_id = "bp", chapter_idx = 2, duration = 20 },
        { id = 13, stable_id = "bp", duration = 5 },
    }, function(value, e) data, err = value, e end)
    fake_client.reportReadAsync = nil
    Assert.eq(reported, 2)
    Assert.is_nil(err)
    Assert.len(data.synced_ids, 2, "只确认无坐标行与已上报成功的第一章")
    Assert.eq(data.synced_ids[1], 13)
    Assert.eq(data.synced_ids[2], 11)
    Assert.eq(reported_payloads[1].ci, 3, "时长上报必须使用微信原始 chapterIdx")
end

-- 全部章节都上报失败时不能报成功：一行都没确认就该让调用方看到错误并重试。
do
    local src = WeChat.new()
    fake_client.reportReadAsync = function(_, _, _, cb)
        cb(nil, "boom")
        return { cancel = function() end }
    end
    local data, err
    src:pushStatsAsync({
        { id = 21, stable_id = "bp", chapter_idx = 1, duration = 10 },
    }, function(value, e) data, err = value, e end)
    fake_client.reportReadAsync = nil
    Assert.is_nil(data)
    Assert.eq(err, "boom")
end

-- 翻页不得上报阅读时长：微信侧时长唯一来源是 pushStatsAsync（本地采集补报）。
-- 一旦这里又开一路心跳，同一段阅读时间会被微信计两遍。
do
    local src = WeChat.new()
    local reported = 0
    fake_client.reportReadAsync = function(_, _, _, cb)
        reported = reported + 1
        cb({ ok = true })
        return { cancel = function() end }
    end
    src:onEvent("page_changed", {
        identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 2 },
        percent = 0.5,
    })
    src:onEvent("document_close", nil)
    Assert.eq(reported, 0, "翻页/关书不得直接上报时长")
    fake_client.reportReadAsync = nil
end

-- getDetailAsync：wire 经 mapper 转 Book，并把封面 URL 记进缓存供 coverRequest 用
do
    local src = WeChat.new()
    fake_client.bookInfoAsync = function(_, book_id, cb)
        Assert.eq(book_id, "b1")
        cb({ book = { bookId = "b1", title = "详情书", author = "某人",
                      cover = "https://img.weread.qq.com/c.jpg" } })
        return { cancel = function() end }
    end
    local book, err
    src:getDetailAsync(REF, function(b, e) book, err = b, e end)
    Assert.is_nil(err)
    Assert.eq(book.stable_id, "b1")
    Assert.eq(book.title, "详情书")
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
        local ok, err
        src:putProgressAsync(REF, pos, function(v, e) ok, err = v, e end)
        return ok, err
    end

    -- 源私有的 chapter_uid 走 extra；REF 无 chapter_idx，归一后为 0
    local UID = { chapter_uid = 42, chapter_idx = 0 }
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
        extra = { chapter_uid = 42, chapter_idx = 3 },
    }))
    Assert.eq(captured.chapter_idx, 7, "上传必须使用微信原始 chapterIdx")
    Assert.eq(captured.chapter_offset, 2500)
    Assert.eq(captured.summary, "序章")
    -- extra 记的是别的章：不复用旧 uid，回落到目录解析（此处目录拉取失败 → 不上传）
    Assert.is_nil(put({ fraction = 0.5, chapter_idx = 7, extra = { chapter_uid = 42, chapter_idx = 3 } }))
    toc_payload["b1"] = nil
    require("source.wechat.toc").clear()
end

-- putProgressAsync：失败时错误原样透传（client 层错误一律是字符串）
do
    fake_client.putProgressAsync = function(_, _, _, cb)
        cb(nil, "写入失败")
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local ok, err
    src:putProgressAsync(REF, {
        fraction = 0.5, extra = { chapter_uid = 42, chapter_idx = 0 },
    }, function(v, e) ok, err = v, e end)
    Assert.is_nil(ok)
    Assert.eq(err, "写入失败")
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
    Assert.is_true(math.abs((pos.chapter_fraction or 0) - 0.5) < 0.001)

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

-- listStoreAsync：无搜索词走分类榜单，有关键词走搜索
do
    local called
    fake_client.storeCatalogAsync = function(_, opts, cb)
        called = opts
        cb({
            books = {
                { bookInfo = { bookId = "s1", title = "榜单书", cover = "https://cdn.example.com/s.jpg" } },
            },
        })
        return { cancel = function() end }
    end
    fake_client.searchAsync = function(_, keyword, _, _, cb)
        called = { search = keyword }
        cb({ books = { { bookId = "k1", title = "搜索书" } } })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local result
    src:listStoreAsync({ page_size = 40 }, function(res) result = res end)
    Assert.eq(called.limit, 40)
    Assert.eq(called.category, "all")
    Assert.eq(#result.data, 1)
    Assert.eq(result.data[1].stable_id, "s1")
    Assert.not_nil(src:coverRequest({ source_id = "wechat", stable_id = "s1" }))

    src:listStoreAsync({ search = "三体", page_size = 10, scope = 16 }, function(res) result = res end)
    Assert.eq(called.search, "三体")
    Assert.eq(#result.data, 1)
    Assert.eq(result.data[1].stable_id, "k1")
end

-- addStoreBookAsync：加入书架后同步本地图书馆
do
    local added_id
    fake_client.addToShelfAsync = function(_, book_id, cb)
        added_id = book_id
        cb({ succ = 1 })
        return { cancel = function() end }
    end
    fake_client.shelfSyncAsync = function(_, cb)
        cb({
            books = { { bookId = added_id, title = "同步书" } },
            bookProgress = {},
        })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local ok, err, title
    src:addStoreBookAsync({ stable_id = "s9", title = "测试书" }, function(v, e, t)
        ok, err, title = v, e, t
    end)
    Assert.eq(added_id, "s9")
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(title, "测试书")
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
    Assert.not_nil(result)

    -- 合法 http(s) 封面入缓存，coverRequest 带回会话头
    local req = src:coverRequest({ source_id = "wechat", stable_id = "b1" })
    Assert.not_nil(req)
    Assert.eq(req.url, "https://cdn.example.com/a.jpg")
    Assert.eq(req.headers.Cookie, "wr_skey=stub")

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
    Assert.eq(src:coverRequest({ source_id = "wechat", stable_id = "b1" }).url,
        "https://cdn.example.com/a2.jpg")

    -- clearCaches 清空封面缓存
    src:clearCaches()
    local req4 = src:coverRequest({ source_id = "wechat", stable_id = "b1" })
    Assert.is_nil(req4)
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
    Assert.eq(annotations[1].chapter_idx, 5)
end

-- pushNotesAsync：划线与想法两段队列必须串起来
do
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
    local chapter_path = require("utils.paths").chapterPath("bpush", 2, "wechat")
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
        local text = require("utils.text").base64Decode(body.markText)
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
    Assert.eq(chapter_fetches, 3)

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

    -- 无划线也无想法：不发请求
    ok = push({ { drawer = "lighten", text = "旧划线", wr_bookmark_id = "bm1", wr_range = "0-3" } })
    Assert.is_true(ok)
    Assert.eq(#calls, 0)
    os.remove(chapter_path)
end

-- 还原打桩，避免影响本文件之后的其它用例
for name, factory in pairs(saved_preload) do
    package.preload[name] = factory
    package.loaded[name] = nil
end
package.loaded["source.wechat"] = nil
