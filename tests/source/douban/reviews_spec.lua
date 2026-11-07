--[[--
豆瓣段评的取消、同步正文回调和坏响应。

@module tests.source.douban.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local pending, calls = nil, 0
package.preload["source.douban.client"] = function()
    return {
        articleAsync = function(_aid, cb)
            cb({ posts = { { contents = { { type = "paragraph", id = 10, data = { text = "测试段落" } } } } } })
            return { cancel = function() end }
        end,
        annotationsAsync = function(_aid, _pids, cb)
            pending = { callback = cb }
            return { cancel = function() pending.cancelled = true end }
        end,
    }
end
package.preload["json"] = function() return require("support.json_stub") end
local Reviews = require("source.douban.reviews")
local job = Reviews.hotspotsAsync({ content_url = "test" }, function() calls = calls + 1 end)
job.cancel()
Assert.is_true(pending.cancelled)
pending.callback({ { note = "测试批注", startContainerId = "10" } })
Assert.eq(calls, 0)

local result, err
Reviews.pageAsync({ content_url = "test" }, "1", function(value, reason) result, err = value, reason end)
pending.callback(nil, "network failed")
Assert.is_nil(result)
Assert.eq(err, "network failed")
Reviews.pageAsync({ content_url = "test" }, "1", function(value) result = value end)
pending.callback({})
Assert.eq(#result.items, 0)
Assert.eq(result.more, false)

local source = require("source.douban").new()
function source:loadTocAsync(_identity, cb)
    cb({ { content_url = "test" } })
    return { cancel = function() end }
end
for _idx, method in ipairs({ "paragraphHotspotsAsync", "paragraphReviewPageAsync" }) do
    local identity = { source_id = "douban", stable_id = "test", chapter_idx = 1 }
    local handle
    if method == "paragraphHotspotsAsync" then
        handle = source:paragraphHotspotsAsync(identity, function() calls = calls + 1 end)
    else
        handle = source:paragraphReviewPageAsync(identity, "1", 1, function() calls = calls + 1 end)
    end
    handle.cancel()
    Assert.is_true(pending.cancelled)
    pending.callback({})
    Assert.eq(calls, 0)
end
