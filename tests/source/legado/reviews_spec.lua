--[[--
阅读 App 段评：真实客户端回包、源接口、离线缓存与段落定位。

@module tests.source.legado.reviews_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field, assign-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
Stubs.install()

local cfg = { server_address = "http://legado.example:1122" }
local connected, delayed_toc, toc_callback, toc_cancelled = true, false, nil, false
local requests = {}
package.preload["json"] = function() return { encode = JSON.encode, decode = JSON.decode } end
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["ui/network/manager"] = function()
    return { isConnected = function() return connected end,
        isOnline = function() error("不能用同步 DNS 检查联网") end }
end
package.preload["http.request"] = function()
    return {
        get = function(url, _opts, cb)
            local request = { url = url, cb = cb, cancelled = false }
            requests[#requests + 1] = request
            return { cancel = function() request.cancelled = true end }
        end,
        post = function() error("阅读 App 段评必须 GET") end,
    }
end
for _idx, name in ipairs({ "json", "utils.settings", "ui/network/manager", "http.request",
    "source.legado", "source.legado.client", "source.legado.mapper", "source.legado.reviews", "book.review_cache" }) do
    package.loaded[name] = nil
end
local Client = require("source.legado.client")
local Reviews = require("source.legado.reviews")
local Mapper = require("source.legado.mapper")
local Cache = require("book.review_cache")
local source = require("source.legado").new()
local identity = { source_id = "legado", stable_id = "https://books.example/a?b=1&c=2", chapter_idx = 2 }
Cache.removeIdentity(identity.source_id, identity.stable_id)
function source:loadTocAsync(_identity, cb)
    if delayed_toc then toc_callback = cb else cb({ {}, { uid = "7", title = "章" } }) end
    return { cancel = function() toc_cancelled = true end }
end
local function answer(data, err)
    requests[#requests].cb(data and JSON.encode({ isSuccess = true, data = data }), err)
end
local summary = { counts = { ["-1"] = 4, ["0"] = 9, ["1"] = 5, ["3"] = 2, ["8"] = 0 },
    keys = { ["1"] = 'key&中文:"\n', ["3"] = "other" } }
local value, reason
local function receive(data, err) value, reason = data, err end

-- 开关默认关闭；reader3 / 轻阅读不宣称支持 Android App 的专用接口。
Assert.is_false(source:paragraphReviewsEnabled())
require("source.review_setting").set("legado", true)
Assert.is_true(source:paragraphReviewsEnabled())
for _idx, address in ipairs({ "http://legado.example/reader3", "http://legado.example/api/5" }) do
    cfg.server_address = address
    Assert.is_false(source:paragraphReviewsEnabled())
    Client.reviewSummaryAsync(identity.stable_id, 7, receive)
    Stubs.flush()
    Assert.is_nil(value)
    Assert.eq(reason, "段评仅支持阅读 App 的 Web 服务")
    Assert.len(requests, 0)
end
cfg.server_address = "http://legado.example:1122"

-- 请求使用目录 uid（7），不是月读的章序号（2）减一；摘要标识原样保留。
source:paragraphHotspotsAsync(identity, receive)
Assert.matches(requests[1].url, "/getReviewSummary%?")
Assert.matches(requests[1].url, "index=7")
Assert.matches(requests[1].url, "url=https%%3A%%2F%%2Fbooks%.example%%2Fa%%3Fb%%3D1%%26c%%3D2")
answer(summary)
Assert.is_nil(reason)
Assert.len(value, 2)
local hotspots = value
Assert.eq(hotspots[1].paragraph, 1)
Assert.eq(Reviews.context(hotspots[1].range)[2], summary.keys["1"])
Assert.eq(hotspots[2].paragraph, 3)

-- 图片段占段号；开头空段、连续换行、被丢弃的 SVG 占位也不能导致后文错位。
local html = Mapper.chapterHtml("章", '第一段原文。\n<img src="https://images.example/p.png">\n第三段原文。',
    function(src) return src end, true)
Assert.matches(html, 'id="moon%-legado%-paragraph%-2"><img')
local spots = source:locateHotspots(hotspots, html)
Assert.len(spots, 2)
Assert.eq(spots[2].text, "第三段原文。")
Assert.eq(spots[2].range, hotspots[2].range)
local marked = Mapper.chapterHtml("章", '\n首段。\n\n<img src="data:image/svg+xml;base64,x">\n后段。',
    function(src) return src end, true)
Assert.matches(marked, 'id="moon%-legado%-paragraph%-2">首段。')
Assert.matches(marked, 'id="moon%-legado%-paragraph%-4">后段。')
Assert.is_nil(marked:find("\2", 1, true))
Assert.len(source:locateHotspots(hotspots, "<h1>旧缓存</h1><p>未编号正文</p>"), 0,
    "旧缓存不能靠猜测段序把评论挂错段")

source:chapterReviewHotspotsAsync(identity, receive)
answer(summary)
Assert.len(value, 1)
Assert.eq(Reviews.context(value[1].range)[1], -1)
Assert.eq(value[1].total, 4)
Assert.eq(value[1].anchor, require("book.review_locate").CHAPTER_ANCHOR)

-- 正文与回复的 id 是不透明字符串，大整数及同一段的 paraData 不得丢失。
source:paragraphReviewPageAsync(identity, hotspots[1].range, 0, receive)
Assert.matches(requests[#requests].url, "/getReviewDetail%?")
Assert.matches(requests[#requests].url, "page=1")
Assert.matches(requests[#requests].url, "paraIndex=1")
Assert.matches(requests[#requests].url, "paraData=key%%26%%E4%%B8%%AD%%E6%%96%%87%%3A%%22%%0A")
local original_id = "18446744073709551617"
answer({ items = { { id = original_id, name = "作者", content = "<b>评论 &amp; 内容</b>",
    time = "2026-11-13", likeCount = 7, replyCount = 9, imageUrl = "https://images.example/comment.png" } },
    hasMore = true, nextCursor = "cursor&%" })
Assert.is_nil(reason)
local first_page = value
Assert.eq(first_page.items[1].content, "评论 & 内容")
Assert.eq(first_page.items[1].author, "作者")
Assert.eq(first_page.items[1].likes, 7)
Assert.eq(first_page.items[1].replies, 9)
Assert.eq(first_page.items[1].images[1].url, "https://images.example/comment.png")
Assert.eq(Reviews.context(first_page.items[1].id, true)[3], original_id)
Assert.is_nil(first_page.total, "接口没给总数，不能伪造成本页条数")
Assert.is_true(first_page.more)
source:paragraphReviewPageAsync(identity, hotspots[1].range, first_page.max_idx, receive)
Assert.matches(requests[#requests].url, "page=2")
Assert.matches(requests[#requests].url, "cursor=cursor%%26%%25")
answer({ items = {}, hasMore = false })
Assert.is_false(value.more)
Assert.eq(value.total, 0)

source:paragraphReviewRepliesAsync(identity, first_page.items[1].id, 0, receive)
Assert.matches(requests[#requests].url, "/getReviewReplies%?")
Assert.matches(requests[#requests].url, "reviewId=" .. original_id)
Assert.matches(requests[#requests].url, "paraIndex=1")
answer({ items = { { id = "reply", name = "乙", content = "回复", replyToName = "丙" } }, hasMore = true })
local replies_page = value
Assert.eq(value.items[1].reply_to, "丙")
source:paragraphReviewRepliesAsync(identity, first_page.items[1].id, replies_page.max_idx, receive)
Assert.matches(requests[#requests].url, "page=2")
answer({ items = {}, hasMore = false })

-- JS 书源的更多页只有 page 信号，没有 cursor，同样按递增页号续拉。
local js_page = Reviews.page({ items = { { id = "js", content = "评论" } }, hasMore = true },
    Reviews.context(hotspots[1].range), 1)
local page, cursor = Reviews.pagination(js_page.max_idx)
Assert.eq(page, 2)
Assert.is_nil(cursor)
Assert.is_true(js_page.more)
Assert.eq(Reviews.page({ items = { { content = "没有 ID", replyCount = 3 } }, hasMore = false },
    Reviews.context(hotspots[1].range), 1).items[1].replies, 0)

-- HTTP 200 的业务失败及损坏回包不能变成空评论成功，也不能清掉旧缓存。
source:paragraphHotspotsAsync(identity, receive)
requests[#requests].cb('{"isSuccess":false,"errorMsg":"段评规则未配置"}')
Assert.is_nil(value)
Assert.eq(reason, "段评规则未配置")
source:paragraphHotspotsAsync(identity, receive)
requests[#requests].cb("<html>old app</html>")
Assert.is_nil(value)
Assert.eq(reason, "响应无效")
Assert.is_nil(Reviews.hotspots({ counts = {} }))
Assert.is_nil(Reviews.hotspots({ counts = { ["x"] = 1 }, keys = {} }))
Assert.is_nil(Reviews.page({ items = {}, hasMore = "yes" }, {}, 1))
Assert.is_nil(Reviews.page({ items = { bad = {} }, hasMore = false }, {}, 1))

-- 离线只保留首页评论已缓存的标记；正文页和回复均可从缓存读取，不发网络。
connected = false
local count = #requests
source:paragraphHotspotsAsync(identity, receive)
Stubs.flush()
Assert.is_nil(reason)
Assert.len(value, 1)
Assert.eq(value[1].range, hotspots[1].range)
source:paragraphReviewPageAsync(identity, hotspots[1].range, 0, receive)
Stubs.flush()
Assert.eq(value.items[1].author, "作者")
source:paragraphReviewRepliesAsync(identity, first_page.items[1].id, 0, receive)
Stubs.flush()
Assert.eq(value.items[1].content, "回复")
Assert.len(requests, count)
local missing = { source_id = "legado", stable_id = "legado-review-no-cache", chapter_idx = 2 }
Cache.removeIdentity(missing.source_id, missing.stable_id)
source:paragraphHotspotsAsync(missing, receive)
Stubs.flush()
Assert.is_nil(value)
Assert.eq(reason, "未联网，无法加载段评")
Assert.len(requests, count)

-- 请求阶段和目录阶段都可取消；迟到响应不得写缓存或启动后续请求。
connected = true
local calls = 0
local job = source:paragraphHotspotsAsync(missing, function() calls = calls + 1 end)
job.cancel()
Assert.is_true(requests[#requests].cancelled)
answer(summary)
Assert.eq(calls, 0)
Assert.is_nil(Cache.hotspots(missing))
delayed_toc, toc_cancelled = true, false
count = #requests
job = source:paragraphHotspotsAsync(missing, function() calls = calls + 1 end)
job.cancel()
Assert.is_true(toc_cancelled)
toc_callback({ {}, { uid = "7" } })
Assert.len(requests, count)
Assert.eq(calls, 0)
source:paragraphReviewPageAsync(identity, "broken", 0, receive)
Stubs.flush()
Assert.is_nil(value)
Assert.eq(reason, "阅读段评位置无效")
source:paragraphReviewPageAsync(identity, hotspots[1].range, "broken", receive)
Stubs.flush()
Assert.is_nil(value)
Assert.eq(reason, "阅读段评分页位置无效")

-- 源的真实正文路径保留段号并预留章评入口；关闭段评也保留段号，以便以后就地开启。
delayed_toc = false
package.loaded["source.chapter"] = nil
package.preload["source.chapter"] = function()
    return {
        openAsync = function(_source, ref, _book, _opts, ops, cb)
            Assert.eq(type(ops.reuse), "function")
            return ops.fetchContent(ref, { uid = "7", title = "章" }, cb)
        end,
        prefetchAsync = function(ref, _book, _toc, _from, _count, ops, cb)
            Assert.is_nil(ops.reuse)
            return ops.fetchContent(ref, { uid = "7", title = "章" }, cb)
        end,
    }
end
source:openBookAsync(identity, { chapter_idx = 2 }, receive)
answer("一段。\n二段。")
Assert.matches(value.html, 'id="moon%-legado%-paragraph%-2">二段。')
Assert.matches(value.html, 'id="moon%-chapter%-reviews"')
cfg.show_paragraph_reviews = false
source:prefetchChaptersAsync(identity, {}, 2, 1, receive)
answer("一段。\n二段。")
Assert.matches(value.html, 'id="moon%-legado%-paragraph%-2">二段。')
Assert.is_nil(value.html:find("moon-chapter-reviews", 1, true))

Cache.removeIdentity(identity.source_id, identity.stable_id)
Cache.removeIdentity(missing.source_id, missing.stable_id)
