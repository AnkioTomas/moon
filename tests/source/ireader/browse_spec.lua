--[[--
掌阅真实分类结构、频道切换、分页去重和失败传播。

@module tests.source.ireader.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Mapper = require("source.ireader.mapper")
local html = [[
<script>var parentId = '10',categoryId = '11';</script>
<a href="https://m.zhangyue.com/category/10/10?currentPage=1">男频</a>
<a href="https://m.zhangyue.com/category/68/68?currentPage=1">女频</a>
<a href="https://m.zhangyue.com/category/92/92?currentPage=1">出版</a>
<a href="https://m.zhangyue.com/category/10/11?currentPage=1">玄幻</a>
<a href="https://m.zhangyue.com/category/10/27?currentPage=1">都市</a>
<span data-order="download">热门书籍</span><span data-order="score">评分最高</span>
<span data-status="0">全部</span><span data-status="3">完结</span>
]]
local page = Mapper.categories(html)
Assert.eq(page.parent, "10")
Assert.eq(page.category, "11")
Assert.len(page.channels, 3)
Assert.len(page.categories, 2)
Assert.eq(page.categories[2].id, "27")
Assert.eq(page.orders[2].id, "score")
Assert.is_nil(Mapper.categories("<html>captcha</html>"))
local card = [[
<li data-type="book" data-id="42"><a><img data-src="https://img/42?a=1&amp;b=2">
<dl><dt>书名</dt><dd class="author">作者</dd><dd class="content ellipsis2">简介</dd></dl></a></li>
]]
local books = Mapper.catalog(card .. card)
Assert.len(books, 1)
Assert.eq(books[1].title, "书名")
Assert.eq(books[1].authors, "作者")
Assert.eq(books[1].intro, "简介")
Assert.eq(books[1].cover, "https://img/42?a=1&b=2")

local requests, mode = {}, "ok"
package.loaded["source.ireader.client"] = {
    categoriesAsync = function(parent, category, cb)
        requests[#requests + 1] = { parent = parent, category = category }
        if mode == "invalid" then cb(nil, "bad catalog"); return end
        local current = Mapper.categories(html)
        if parent == "92" then
            current.parent, current.category = "92", "93"
            current.categories = { { id = "93", title = "小说" } }
            current.statuses = { { id = "0", title = "全部" } }
        elseif category == "27" then current.category = category end
        cb(current)
        return { cancel = function() end }
    end,
    catalogAsync = function(opts, index, cb)
        local request = { opts = opts, page = index, cb = cb }
        requests[#requests + 1] = request
        if mode == "delayed" and index == 2 then
            return { cancel = function() request.cancelled = true end }
        end
        if mode == "failed" and index == 2 then cb(nil, "network failed"); return end
        cb({
            { source_id = "ireader", stable_id = tostring(index), title = "书" },
            { source_id = "ireader", stable_id = "duplicate", title = "重复" },
        }, nil, index < 3)
        return { cancel = function() request.cancelled = true end }
    end,
}
local source = require("source.ireader").new()
local result, reason, calls = nil, nil, 0
local function done(value, err) result, reason, calls = value, err, calls + 1 end
source:browseAsync({ node = "h5_ch_female", limit = 4 }, done)
Assert.eq(requests[1].parent, "68", "兼容旧频道节点")
Assert.len(result.data, 4)
Assert.is_nil(reason)
Assert.len(result.groups, 4)
Assert.eq(result.groups[2].title, "分类")
Assert.eq(result.groups[3].chips[2].id, "10:11:score:0")

source:browseAsync({ node = "10:27:score:3", limit = 2 }, done)
Assert.eq(requests[#requests].opts.category, "27")
Assert.eq(requests[#requests].opts.order, "score")
Assert.eq(requests[#requests].opts.status, "3")
Assert.eq(result.groups[1].chips[3].id, "92:92:score:0", "出版不保留不支持的完结筛选")
source:browseAsync({ node = "92:92:score:3", limit = 2 }, done)
Assert.eq(requests[#requests].opts.status, "0")
Assert.eq(requests[#requests].opts.category, "93")

mode = "failed"
source:browseAsync({ limit = 4 }, done)
Assert.is_nil(result)
Assert.eq(reason, "network failed", "中间页失败不能伪装完整列表")
mode = "invalid"
source:browseAsync({}, done)
Assert.eq(reason, "bad catalog")
mode = "delayed"
local handle = source:browseAsync({ limit = 4 }, done)
local pending = requests[#requests]
local before = calls
handle:cancel()
Assert.is_true(pending.cancelled, "同步首阶段后取消当前分页请求")
pending.cb({}, nil, false)
Assert.eq(calls, before)
