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
