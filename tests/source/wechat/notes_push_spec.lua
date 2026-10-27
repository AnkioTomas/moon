--[[--
source.wechat.notes_push：删除先行、预检失败整轮失败、远端已没有的 bookmarkId 被清掉、取消后不回调。
@module tests.source.wechat.notes_push_spec
--]]

local Assert = require("support.assert")
local Stubs = require("support.stubs")
Stubs.install()

local NotesPush = require("source.wechat.notes_push")

--- 只记调用、按表回包的假客户端（回包走 nextTick，模拟真异步）。
local function fakeClient(replies)
    local calls = {}
    ---@type { calls: string[], [string]: any }
    local client = { calls = calls }
    local function method(name)
        return function(_self, ...)
            local args = { ... }
            local cb = args[#args]
            calls[#calls + 1] = name
            local reply = replies[name]
            require("ui/uimanager"):nextTick(function()
                if type(reply) == "function" then reply = reply() end
                if reply == false then cb(nil, name .. " failed") else cb(reply or {}) end
            end)
            return { cancel = function() calls[#calls + 1] = "cancel:" .. name end }
        end
    end
    for _idx, name in ipairs({ "removeBookmarkAsync", "deleteReviewAsync", "bookmarkListAsync",
        "myReviewsAsync", "addBookmarkAsync", "updateBookmarkAsync", "editReviewAsync",
        "addReviewAsync", "bookInfoAsync" }) do
        client[name] = method(name)
    end
    return client
end

local identity = { source_id = "wechat", stable_id = "b1", chapter_idx = 1 }

do -- 删除墓碑：先删想法再删划线，删完从注解里移除，后续无事可做即成功
    local client = fakeClient({ bookmarkListAsync = { updated = {} }, myReviewsAsync = { reviews = {} } })
    local annotations = { { wr_deleted = true, wr_bookmark_id = "bm1", wr_review_id = "rv1" } }
    local ok, err
    NotesPush.run(client, identity, "c1", "<p>x</p>", annotations, function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(client.calls[1], "deleteReviewAsync")
    Assert.eq(client.calls[2], "removeBookmarkAsync")
    Assert.len(annotations, 0)
end

do -- 只有想法的墓碑（没记过划线 id）：按 range 在远端找到划线一并删掉
    local client = fakeClient({
        bookmarkListAsync = { updated = { { chapterUid = "c1", range = "10-20", bookmarkId = "bm9" } } },
        myReviewsAsync = { reviews = {} },
    })
    local annotations = { { wr_deleted = true, wr_review_id = "rv1", wr_range = "10-20" } }
    local ok
    NotesPush.run(client, identity, "c1", "<p>x</p>", annotations, function(o) ok = o end)
    Stubs.flush()
    Assert.is_true(ok)
    Assert.eq(client.calls[1], "deleteReviewAsync")
    Assert.eq(client.calls[2], "bookmarkListAsync")
    Assert.eq(client.calls[3], "removeBookmarkAsync")
    Assert.len(annotations, 0)
end

do -- 预检失败：整轮失败，带上错误
    local client = fakeClient({ bookmarkListAsync = false })
    local ok, err
    NotesPush.run(client, identity, "c1", "<p>x</p>", {}, function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.eq(err, "bookmarkListAsync failed")
end

do -- 远端已没有的 bookmarkId 被清掉（下轮当新划线重传），删除请求失败则停在删除
    local client = fakeClient({ bookmarkListAsync = { updated = {} }, myReviewsAsync = { reviews = {} } })
    local item = { drawer = "lighten", text = "t", wr_bookmark_id = "gone" }
    NotesPush.run(client, identity, "c1", nil, { item }, function() end)
    Stubs.flush()
    Assert.is_nil(item.wr_bookmark_id)

    client = fakeClient({ removeBookmarkAsync = false })
    local ok
    local annotations = { { wr_deleted = true, wr_bookmark_id = "bm1" } }
    NotesPush.run(client, identity, "c1", nil, annotations, function(o) ok = o end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.len(annotations, 1, "删除失败保留墓碑下轮重试")
end

do -- 取消：在途请求被取消，迟到回包不回调
    local client = fakeClient({})
    local called = false
    local job = NotesPush.run(client, identity, "c1", nil, {}, function() called = true end)
    job.cancel()
    Stubs.flush()
    Assert.is_false(called)
    Assert.eq(client.calls[2], "cancel:bookmarkListAsync")
end

do -- 想法列表预检失败只跳过想法对账，不阻断划线：已有 review id 保留
    local client = fakeClient({ bookmarkListAsync = { updated = {} }, myReviewsAsync = false })
    local item = { drawer = "lighten", text = "t", wr_bookmark_id = "gone", wr_review_id = "rv1" }
    local ok, err
    NotesPush.run(client, identity, "c1", nil, { item }, function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_nil(err)
    Assert.eq(item.wr_review_id, "rv1")
    Assert.is_nil(item.wr_bookmark_id)
end

do -- 新划线定位：range 原文走 Position 缓存（开书记住的那份），同步命中不重拉整章
    local Toc = require("source.wechat.toc")
    local Position = require("source.wechat.progress")
    local old_read, old_load = Toc.read, Position.loadAsync
    Toc.read = function() return { { uid = "c1" } } end
    local load_calls = 0
    Position.loadAsync = function(_identity, _chapter, cb)
        load_calls = load_calls + 1
        -- 缓存命中：同步回调、返回 nil（与 Position.loadAsync 真实行为一致）
        cb('<html><head><title>tttttttttt</title></head><body><p>hello world</p></body></html>', "html")
        return nil
    end
    local submitted = false
    local item = {
        drawer = "lighten", text = "hello",
        pos0 = "/html/body/p/text().0", pos1 = "/html/body/p/text().5",
    }
    local client = fakeClient({
        bookmarkListAsync = function()
            if not submitted then return { updated = {} } end
            return { updated = { {
                chapterUid = "c1", range = item.wr_range, bookmarkId = "bm-new",
                markText = "hello", type = 1,
            } } }
        end,
        myReviewsAsync = { reviews = {} },
        addBookmarkAsync = function() submitted = true; return { bookmarkId = "bm-new" } end,
        bookInfoAsync = { book = { version = 7 } },
    })
    local ok, err
    NotesPush.run(client, identity, "c1",
        "<html><body><p>hello world</p></body></html>", { item },
        function(o, e) ok, err = o, e end)
    Stubs.flush()
    Toc.read, Position.loadAsync = old_read, old_load
    Assert.is_true(ok)
    Assert.is_nil(err)
    Assert.eq(load_calls, 1)
    -- 53 = wire 原文里 <p> 之前的全部 rune（head/title 计入），与本地壳无关
    Assert.eq(item.wr_range, "53-58")
    Assert.eq(item.wr_bookmark_id, "bm-new")
end

do -- 想法清单拿不到：新想法不推（认不回上轮已成功的会重复），报失败留脏；划线与已有想法照常
    local client = fakeClient({ bookmarkListAsync = { updated = {} }, myReviewsAsync = false })
    local item = { drawer = "lighten", text = "t", note = "想法", wr_review_only = true, wr_range = "1-2" }
    local ok, err
    NotesPush.run(client, identity, "c1", nil, { item }, function(o, e) ok, err = o, e end)
    Stubs.flush()
    Assert.is_nil(ok)
    Assert.not_nil(err)
    Assert.is_nil(item.wr_review_id)
    for _, name in ipairs(client.calls) do Assert.is_true(name ~= "addReviewAsync", "不得重复新增想法") end
end
