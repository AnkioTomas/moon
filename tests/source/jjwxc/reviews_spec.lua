--[[--
晋江章评与段评分流、分页、坏响应、章节归属及取消。

@module tests.source.jjwxc.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local pending, request, called
package.loaded["json"] = JSON
package.loaded["source.jjwxc.protocols"] = { current = function() end }
package.loaded["http.request"] = { get = function(url, _opts, cb)
    pending = cb
    request = { url = url, cancel = function() request.cancelled = true end }
    return request
end }
package.loaded["source.jjwxc.reviews"] = nil
local Reviews = require("source.jjwxc.reviews")
Assert.eq(Reviews.item({ commentBody = "第一行&lt;br&gt;第二行&lt;BR /&gt;第三行" }).content,
    "第一行\n第二行\n第三行", "转义换行标签不能直接显示")
local formatted = Reviews.item({ commentBody = "<p>第一行</p><p><b>第二行</b>&nbsp;[紫糖]</p>" })
Assert.eq(formatted.content, "第一行\n第二行 [紫糖]")
Assert.is_true(formatted.inline_images["[紫糖]"] ~= nil, "清理标签后保留表情")
local emoji_body = " [紫糖][狗头][紫糖]&#91;红心&#93;<br>😀[未知表情] "
local emoji_item = Reviews.item({ commentId = "emoji", commentBody = emoji_body })
Assert.eq(emoji_item.content, "[紫糖][狗头][紫糖][红心]\n😀[未知表情]")
Assert.matches(emoji_item.inline_images["[紫糖]"].url, "66baeed24ae82_531%.png$")
Assert.eq(emoji_item.inline_images["[狗头]"].url, "https://i9-static.jjwxc.net/tmp/emoji/dog.png")
Assert.eq(emoji_item.inline_images["[红心]"].headers.Referer, "https://www.jjwxc.net/")
Assert.is_nil(emoji_item.inline_images["[未知表情]"])
Assert.len(emoji_item.images, 0, "表情不能变成卡片配图")
Assert.is_nil(Reviews.item({ commentBody = "普通评论 😀[未知表情]" }).inline_images)
Assert.len(Reviews.hotspots({}), 0)
Assert.is_nil(Reviews.hotspots({ message = "错误对象" }))
Assert.is_nil(Reviews.hotspots({ { paragraph_id = 1 } }))
Reviews.hotspotsAsync("9", "23", function(value, err) called = { value, err } end)
pending(JSON.encode({ code = 200, data = { { paragraph_id = 1, comment_total = "bad" } } }))
Assert.is_nil(called[1])
Assert.eq(called[2], "响应无效")
Reviews.pageAsync("9", "23", -2, 20, function(value, err) called = { value, err } end)
Assert.matches(request.url, "novelId=9&chapterId=23&paragraph_id=%-2&offset=20")
pending(JSON.encode({ code = 200, data = { commentTotal = "21", commentList = { { commentId = "7", commentBody = "测试评论" } } } }))
Assert.eq(called[1].max_idx, 21)
Assert.is_false(called[1].more)
Reviews.pageAsync("9", "23", 1, 0, function(value, err) called = { value, err } end)
pending(JSON.encode({ code = 200, data = { commentTotal = 0, commentList = {} } }))
Assert.len(called[1].items, 0)
Assert.is_nil(Reviews.page({ commentTotal = 2, commentList = { "bad" } }, 0))
Assert.is_nil(Reviews.page({ commentList = {} }, 0))
Assert.is_nil(Reviews.page({ commentTotal = 0, commentList = { error = "bad" } }, 0))
Reviews.pageAsync("9", "23", 1, 0, function(value, err) called = { value, err } end)
pending(nil, "网络故障")
Assert.eq(called[2], "网络故障")

local hotspots = { { range = "-2", total = 37 }, { range = "6", total = 205 } }
package.loaded["book.review_cache"] = {
    hotspotsAsync = function(_identity, fetch, cb) return fetch(cb) end,
    pageAsync = function(_identity, _range, _offset, fetch, cb) return fetch(cb) end,
}
package.loaded["source.jjwxc.reviews"] = {
    inlineImages = Reviews.inlineImages,
    hotspotsAsync = function(_novel, uid, cb)
        Assert.eq(uid, "23")
        cb(hotspots)
        return { cancel = function() end }
    end,
    pageAsync = function(_novel, uid, range, offset, cb)
        Assert.eq(uid, "23"); Assert.eq(range, -2); Assert.eq(offset, 0)
        pending = cb
        request = { cancel = function() request.cancelled = true end }
        return request
    end,
}
package.loaded["source.jjwxc"] = nil
local source = require("source.jjwxc").new()
source.loadTocAsync = function(_self, _identity, cb)
    cb({ { uid = "23" } })
    return { cancel = function() error("不应取消已完成目录请求") end }
end
local identity = { source_id = "jjwxc", stable_id = "9", chapter_idx = 1 }
source:paragraphHotspotsAsync(identity, function(value) called = value end)
Assert.len(called, 1)
Assert.eq(called[1].range, "6")
source:chapterReviewHotspotsAsync(identity, function(value) called = value end)
Assert.len(called, 1)
Assert.eq(called[1].range, "-2")
Assert.eq(called[1].anchor, "moon-chapter-reviews")
called = nil
local handle = source:paragraphReviewPageAsync(identity, "-2", 0, function() called = true end)
handle.cancel()
Assert.is_true(request.cancelled)
pending({})
Assert.is_nil(called, "换章取消后不得展示旧评论")

package.loaded["book.review_cache"].pageAsync = function(_identity, _range, _offset, _fetch, cb)
    cb({ items = { { content = "旧缓存<br>[紫糖]" } } })
    return { cancel = function() end }
end
source:paragraphReviewPageAsync(identity, "-2", 0, function(value) called = value end)
Assert.matches(called.items[1].inline_images["[紫糖]"].url, "66baeed24ae82_531%.png$")
Assert.eq(called.items[1].content, "旧缓存\n[紫糖]", "修正旧缓存中的标签，不丢弃离线评论")
