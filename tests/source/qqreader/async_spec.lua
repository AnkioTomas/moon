--[[-- QQ阅读进度多阶段取消与换号竞态。 @module tests.source.qqreader.async_spec --]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local cookie, detail_delay, push_delay, late = "111", false, false, nil
local cancelled, pushed = {}, 0
local toc = { { uid = "1", title = "one" }, { uid = "2", title = "two" } }
package.preload["source.toc"] = function() return { index = function() return 2 end } end
package.preload["source.qqreader.client"] = function()
    return {
        cookie = function() return cookie end,
        detailAsync = function(_id, cb)
            local function done() cb({ title = "fixture", inShelf = 1, lastReadChapterId = 2 }) end
            if detail_delay then late = done else done() end
            return { cancel = function() cancelled.detail = true end }
        end,
        updateReadAsync = function(_id, _chapter, cb)
            pushed = pushed + 1
            if push_delay then late = function() cb(true) end else cb(true) end
            return { cancel = function() cancelled.push = true end }
        end,
        bookCommentsAsync = function(_id, cb)
            cb({ commentCount = 32, comments = {
                { commentId = "c1", content = "fixture", user = { nickname = "author" } },
            } })
            return { cancel = function() end }
        end,
    }
end
local source = require("source.qqreader").new()
local identity = { source_id = "qqreader", stable_id = "9" }

do
    source.loadTocAsync = function(_self, _identity, cb)
        late = function() cb(toc) end
        return { cancel = function() cancelled.toc = true end }
    end
    local called = false
    local job = source:getProgressAsync(identity, function() called = true end)
    job.cancel()
    Assert.is_true(cancelled.toc)
    Assert.is_nil(cancelled.detail, "同步详情不能覆盖下一阶段句柄")
    late()
    Assert.is_false(called)
end

for _idx, stage in ipairs({ "detail", "push" }) do
    cancelled, detail_delay, push_delay = {}, stage == "detail", stage == "push"
    source.loadTocAsync = function(_self, _identity, cb)
        cb(toc)
        return { cancel = function() cancelled.toc = true end }
    end
    local called = false
    local job = source:putProgressAsync(identity, { chapter_idx = 2 }, function() called = true end)
    job.cancel()
    Assert.is_true(cancelled[stage])
    Assert.is_nil(cancelled.toc)
    late()
    Assert.is_false(called)
end

do
    cookie, detail_delay, pushed = "111", true, 0
    local result, err
    source:putProgressAsync(identity, { chapter_idx = 2 }, function(value, reason) result, err = value, reason end)
    cookie = "222"
    late()
    Assert.is_nil(result)
    Assert.matches(err, "账号已变化")
    Assert.eq(pushed, 0)
end

do
    local page
    source:bookReviewsAsync(identity, function(value) page = value end)
    Assert.len(page.items, 1)
    Assert.eq(page.total, 32)
    Assert.is_true(page.more)
    Assert.matches(page.title, "预览 1/32")
end
