--[[--
知乎章末评论：官方接口、原样游标、回复映射、短篇 / 长篇目标及取消。

@module tests.source.zhihu.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg = require("utils.settings").getSource("zhihu")
cfg.cookie = "z_c0=comment-fixture"
local pending = {}
package.loaded["http.request"] = {
    get = function(url, options, cb)
        local item = { url = url, options = options, cb = cb }
        pending[#pending + 1] = item
        return { cancel = function() item.cancelled = true end }
    end,
}
local Client = require("source.zhihu.client")
local result, err, calls = nil, nil, 0
local function done(value, reason) result, err, calls = value, reason, calls + 1 end
local function wire()
    return {
        data = { {
            id = "101", content = '<p>甲 &amp; 乙<br>下一行</p><img src="https://pic.test/a.jpg?a=1&amp;b=2">',
            author = { name = "读者" }, like_count = 8, child_comment_count = 10, created_time = 1700000000,
            reply_to_author = { name = "另一位读者" },
        } },
        paging = { is_end = false, next = "https://api.zhihu.com/comment_v5/?offset=sr1%3Aabc%2B%2F%3D&limit=10" },
        counts = { total_counts = 380 },
    }
end
Client.reviewsAsync("22", 0, false, done)
Assert.matches(pending[#pending].url, "/comment_v5/paid_column_section_manuscripts/22/root_comment%?")
Assert.matches(pending[#pending].url, "order_by=score&offset=$", "首页用空游标，旧版评论分页不接受数字 0")
Assert.eq(pending[#pending].options.headers.Cookie, cfg.cookie)
pending[#pending].cb(JSON.encode(wire()))
Assert.eq(result.total, 380)
Assert.is_true(result.more)
Assert.eq(result.max_idx, "sr1:abc+/=", "游标不是数字，不得截断或二次解码")
local item = result.items[1]
Assert.eq(item.id, "101")
Assert.eq(item.content, "甲 & 乙\n下一行")
Assert.eq(item.author, "读者")
Assert.eq(item.likes, 8)
Assert.eq(item.replies, 10)
Assert.eq(item.reply_to, "另一位读者")
Assert.eq(item.time, 1700000000)
Assert.eq(item.images[1].url, "https://pic.test/a.jpg?a=1&b=2")
Assert.eq(item.images[1].headers.Referer, "https://www.zhihu.com/")
Client.reviewsAsync("22", result.max_idx, false, done)
Assert.matches(pending[#pending].url, "offset=sr1%%3Aabc%%2B%%2F%%3D$")
Client.reviewsAsync("101", 0, true, done)
Assert.matches(pending[#pending].url, "/comment/101/child_comment%?limit=5&order_by=ts&offset=$")
local last = wire()
last.paging.is_end = true
last.paging.next = nil
pending[#pending].cb(JSON.encode(last))
Assert.is_false(result.more)
Client.reviewsAsync("22", "0", false, done)
Assert.matches(pending[#pending].url, "offset=0$", "服务端返回的字符串游标仍原样带回")

local emoji = wire()
emoji.data[1].content = '甲[捂脸][捂脸][未知表情]<img alt="[赞]" src="https://pic.test/emoji.png">'
    .. '<img src="https://pic.test/photo.jpg">'
Client.reviewsAsync("101", 0, true, done)
pending[#pending].cb(JSON.encode(emoji))
Assert.eq(result.items[1].content, "甲[捂脸][捂脸][未知表情][赞]", "原始文案保留，图片表情的 alt 不丢")
Assert.is_true(result.items[1].inline_images["[捂脸]"] ~= nil, "根段评与回复共用表情映射")
Assert.is_true(result.items[1].inline_images["[赞]"] ~= nil)
Assert.is_nil(result.items[1].inline_images["[未知表情]"], "未知表情保持原文，不编造图片地址")
Assert.len(result.items[1].images, 1, "表情不混入普通配图")
Assert.eq(result.items[1].images[1].url, "https://pic.test/photo.jpg")

for _idx, bad in ipairs({
    {}, { error = { code = 1 } }, { data = {}, paging = { is_end = false }, counts = { total_counts = 3 } },
    { data = {}, paging = { is_end = false, next = "https://api.zhihu.com/?offset=0" },
        counts = { total_counts = 3 } },
}) do
    Client.reviewsAsync("22", 0, false, done)
    pending[#pending].cb(JSON.encode(bad))
    Assert.is_nil(result)
    Assert.eq(err, "无法获取段评", "坏响应不能伪装成无评论")
end
Client.reviewsAsync("22", 0, false, done)
pending[#pending].cb(nil, "network failed")
Assert.eq(err, "network failed")
local Auth = require("source.auth")
Auth.reset()
Client.reviewsAsync("22", 0, false, done)
pending[#pending].cb(nil, "HTTP 401", { code = 401 })
Assert.is_true(Auth.expired("zhihu"))
Auth.reset()

local cache_keys = {}
package.loaded["book.review_cache"] = {
    hotspotsAsync = function(_identity, fetch, cb) return fetch(cb) end,
    pageAsync = function(identity, range, offset, fetch, cb)
        cache_keys[#cache_keys + 1] = { identity, range, offset }
        return fetch(cb)
    end,
}
local source = require("source.zhihu").new()
local short = { source_id = "zhihu", stable_id = "11/22", book = { title = "短篇" } }
source:chapterReviewHotspotsAsync(short, done)
pending[#pending].cb(JSON.encode(wire()))
Assert.len(result, 1)
Assert.eq(result[1].range, "22")
Assert.eq(result[1].text, "短篇")
Assert.eq(result[1].badge, "380")
Assert.eq(result[1].heading, "章节评论")
Assert.eq(cache_keys[#cache_keys][1], short, "整篇 EPUB 不需要伪造 chapter_idx")
local long = { source_id = "zhihu", stable_id = "11", chapter_idx = 2 }
function source:loadTocAsync(_identity, cb)
    cb({ { uid = "22", title = "第一章" }, { uid = "33", title = "第二章" } })
    return { cancel = function() error("已完成目录请求不能覆盖当前评论请求") end }
end
local job = source:chapterReviewHotspotsAsync(long, done)
Assert.matches(pending[#pending].url, "/paid_column_section_manuscripts/33/root_comment%?")
local before = calls
job.cancel()
Assert.is_true(pending[#pending].cancelled)
pending[#pending].cb(JSON.encode(wire()))
Assert.eq(calls, before, "取消后迟到的评论不得覆盖目标")
source:chapterReviewHotspotsAsync(long, done)
pending[#pending].cb(JSON.encode(wire()))
Assert.eq(result[1].text, "第二章")

local legacy = wire()
legacy.counts.total_counts = 4
legacy.data[1].child_comment_count = 3
legacy.paging = {
    is_end = true,
    is_start = true,
    next = "https://api.zhihu.com/comment_v5/?offset=5_11554576136_0&order_by=score",
}
source:chapterReviewHotspotsAsync(long, done)
Assert.matches(pending[#pending].url, "offset=$", "长篇旧版分页的首页也必须是空游标")
pending[#pending].cb(JSON.encode(legacy))
Assert.eq(result[1].badge, "4", "数量气泡只放数字，且总数包含回复")

source:paragraphReviewRepliesAsync(short, "101", "1700000000_123_0", done)
Assert.eq(cache_keys[#cache_keys][2], "reply:101", "回复缓存与根评论缓存不串")
Assert.eq(cache_keys[#cache_keys][3], "1700000000_123_0")
Assert.matches(pending[#pending].url, "offset=1700000000_123_0$")
local empty = wire()
empty.data, empty.counts.total_counts, empty.paging.is_end = {}, 0, true
source:chapterReviewHotspotsAsync(short, done)
pending[#pending].cb(JSON.encode(empty))
Assert.len(result, 1, "零评论仍保留独立章评入口，与接口失败分开处理")
Assert.eq(result[1].badge, "0")
