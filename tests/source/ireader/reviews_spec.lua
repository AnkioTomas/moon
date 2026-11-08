--[[--
掌阅公开整书书评：只取首屏 HTML、异常与取消；不读取电脑账号。

@module tests.source.ireader.reviews_spec
--]]

local Assert = require("support.assert")
local Mapper = require("source.ireader.mapper")
local card = [[<li><div class="sns_user"><div class="info"><i class="vm">读者 &amp; 甲</i>
<div class="stars sns_stars"><span class="cur r8"></span></div></div></div>
<p class="con_dec">好书<br>值得&lt;b&gt;再读&lt;/b&gt;。</p>
<span class="sns_time">昨天</span></li>]]
local first = '<ul class="sns_commentlist" rel="" curpage="1" totalpage="13">' .. card .. '</ul>'
local parsed = Mapper.reviews("<nav><li>导航</li></nav>" .. first)
Assert.len(parsed.items, 1)
Assert.eq(parsed.items[1].author, "读者 & 甲")
Assert.eq(parsed.items[1].text, "好书\n值得 再读 。")
Assert.eq(parsed.items[1].time, "昨天")
Assert.eq(parsed.items[1].grade, 8)
Assert.len(Mapper.reviews('<ul class="sns_commentlist" curpage="1" totalpage="0"></ul>').items, 0)
Assert.is_nil(Mapper.reviews("<html>captcha</html>"))
Assert.len(Mapper.reviews('<ul class="sns_commentlist">' .. card .. '</ul>').items, 1,
    "不依赖未使用的分页元数据")
Assert.is_nil(Mapper.reviews('<ul class="sns_commentlist"><li>坏卡片</li></ul>'))
Assert.is_nil(Mapper.reviews('<ul class="sns_commentlist">' .. card .. '<li>坏卡片</li></ul>'),
    "不返回部分成功列表")
Assert.is_nil(Mapper.reviews('<ul class="sns_commentlist">bad response</ul>'))

local requests = {}
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local request = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = request
        return { cancel = function() request.cancelled = true end }
    end,
}
local Client = require("source.ireader.client")
Client.session = function() error("公开书评不能读取电脑账号") end
local source = require("source.ireader").new()
---@type IReaderReviewPage|nil
local result
local reason, calls = nil, 0
local identity = { source_id = "ireader", stable_id = "42" }
local function done(page, err) result, reason, calls = page, err, calls + 1 end
source:bookReviewsAsync(identity, done)
local request = requests[#requests]
Assert.eq(request.url, "https://m.zhangyue.com/comment/42")
Assert.eq(request.opts.accept, "text/html")
Assert.is_nil(request.opts.headers.Cookie)
Assert.is_true(request.opts.headers["User-Agent"]:find("Mobile", 1, true) ~= nil)
request.cb(first)
Assert.is_nil(reason)
Assert.eq(result.items[1].author, "读者 & 甲")
Assert.len(requests, 1, "官网还有后续页也只请求一次")
request.cb("<html>captcha</html>")
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
request.cb(nil, "网络不可用，请先连接 Wi-Fi")
Assert.eq(reason, "网络不可用，请先连接 Wi-Fi")
request.cb(first, "网络失败")
Assert.is_nil(result)
Assert.eq(reason, "网络失败")

local handle = source:bookReviewsAsync(identity, done)
request = requests[#requests]
local before = calls
handle.cancel()
Assert.is_true(request.cancelled)
request.cb(first)
Assert.eq(calls, before)
for _idx, name in ipairs({ "paragraphHotspotsAsync", "chapterReviewHotspotsAsync" }) do
    Assert.is_nil(source[name], "整书书评不伪装为章评或段评")
end
