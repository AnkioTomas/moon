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
local progress_ui = { shown = 0, closed = 0, progress = {} }

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
    }
end)
stub("source.wechat.client", function()
    return {
        new = function() return fake_client end,
        sessionHeaders = function() return { Cookie = "wr_skey=stub" } end,
    }
end)
stub("source.wechat.chapter", function() return {} end)
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
        reconcileAsync = function(_, books, _, cb)
            cb({ pulled = #books, pushed = 0, hidden = 0, conflicts = 0, skipped = false })
            return { cancel = function() end }
        end,
    }
end)

package.loaded["source.wechat"] = nil
local WeChat = require("source.wechat")

local REF = { source_id = "wechat", stable_id = "b1", book = { title = "微信书" } }

do
    local caps = WeChat.new():capabilities()
    Assert.is_false(caps.scrape)
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
    local captured
    fake_client.putProgressAsync = function(_, stable_id, progress, chapter_uid, cb)
        captured = { stable_id = stable_id, progress = progress, chapter_uid = chapter_uid }
        cb({ ok = true })
        return { cancel = function() end }
    end
    local src = WeChat.new()

    local function put(pos)
        local ok, err
        src:putProgressAsync(REF, pos, function(v, e) ok, err = v, e end)
        return ok, err
    end

    Assert.is_true(put({ fraction = 0 }))
    Assert.eq(captured.progress, 0)
    Assert.is_true(put({ fraction = 1 }))
    Assert.eq(captured.progress, 100)
    Assert.is_true(put({ fraction = 0.5 }))
    Assert.eq(captured.progress, 50)
    -- 四舍五入：0.666 → 67
    Assert.is_true(put({ fraction = 0.666 }))
    Assert.eq(captured.progress, 67)
    -- clampFraction 兼容 1..100 百分数入参
    Assert.is_true(put({ fraction = 25 }))
    Assert.eq(captured.progress, 25)
    -- 缺进度兜底：fraction 缺失 / pos 为 nil 都按 0 上传
    Assert.is_true(put({}))
    Assert.eq(captured.progress, 0)
    Assert.is_true(put(nil))
    Assert.eq(captured.progress, 0)
    -- stable_id 透传
    Assert.eq(captured.stable_id, "b1")
    -- locator（XPointer）与 chapter_idx（目录序号）都不是微信 chapterUid，不上传；
    -- 只有显式 chapter_uid 才透传
    Assert.is_true(put({ fraction = 0.5, locator = "epubcfi(/6/4)", chapter_idx = 3 }))
    Assert.is_nil(captured.chapter_uid)
    Assert.is_true(put({ fraction = 0.5, chapter_uid = 42 }))
    Assert.eq(captured.chapter_uid, 42)
end

-- putProgressAsync：失败时错误透传（table err 取 message）
do
    fake_client.putProgressAsync = function(_, _, _, _, cb)
        cb(nil, { message = "写入失败" })
        return { cancel = function() end }
    end
    local src = WeChat.new()
    local ok, err
    src:putProgressAsync(REF, { fraction = 0.5 }, function(v, e) ok, err = v, e end)
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

    -- 自带 chapter_idx 时直接回调，不再拉目录
    wire = { percent = 10, chapterIdx = 7, chapterUid = "99" }
    pos = get()
    Assert.eq(pos.chapter_idx, 7)
    Assert.eq(pos.fraction, 0.1)
end

-- getProgressAsync：网络失败错误透传；取消后迟到的回调被丢弃
do
    fake_client.getProgressAsync = function(_, _, cb)
        cb(nil, { message = "拉取失败" })
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

-- 还原打桩，避免影响本文件之后的其它用例
for name, factory in pairs(saved_preload) do
    package.preload[name] = factory
    package.loaded[name] = nil
end
package.loaded["source.wechat"] = nil
