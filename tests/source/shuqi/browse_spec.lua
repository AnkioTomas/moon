--[[--
书旗官网书库：动态筛选、分页、旧节点迁移和取消。

@module tests.source.shuqi.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Mapper = require("source.shuqi.mapper")
local category = "fc=7&st=0&sz=0&tm=0&wd=10"
local filters = [[
<div class="selectview page-width">
<div class="selectarea clear"><h6>作品类型:</h6>
<script>console.log("<a href='/bad'>")</script><ul>
<li class="active"><a href="/store?&amp;sz=0">全部</a></li>
<li class=""><a href="/store?&amp;sz=2">女频</a></li></ul></div>
<div class="selectarea clear filter-container"><h6>作品分类:</h6>
<div class="active default-item"><a href="/store?sz=0&amp;fc=0&amp;wd=10&amp;tm=0&amp;st=0&amp;">不限</a></div><ul>
<li class=""><a href="/store?sz=0&amp;fc=7&amp;wd=10&amp;tm=0&amp;st=0&amp;">都市</a></li>
</ul></div></div><div class="store-content">
]]
local function pageHtml(page, next_page)
    local cards = {}
    for index = 1, 24 do
        local id = (page - 1) * 24 + index
        cards[#cards + 1] = '<li><a href="/book/' .. id .. '.html"><img src="//img.test/cover.jpg"><h3>书' .. id
            .. '</h3></a><p class="store-tag clear"><a href="/author/name">作者：作者 </a></p>'
            .. '<a><p class="store-des">简介&amp;摘要</p></a></li>'
    end
    return filters .. '<ul class="store-ul clear">' .. table.concat(cards) .. '</ul>'
        .. (next_page and '<a href="/store?page=' .. (page + 1) .. '">下一页</a>' or "")
end
local books, groups, more = Mapper.store(pageHtml(1, true))
Assert.len(books, 24)
Assert.eq(books[1].authors, "作者")
Assert.eq(books[1].intro, "简介&摘要")
Assert.eq(books[1].cover, "https://img.test/cover.jpg")
Assert.len(groups, 2)
Assert.eq(groups[1].active, "sz=0")
Assert.eq(groups[2].chips[2].id, category)
Assert.eq(groups[2].active, "fc=0&st=0&sz=0&tm=0&wd=10")
Assert.is_true(more)
Assert.is_nil(Mapper.store("<title>维护</title>"))
Assert.len(Mapper.store(filters .. '<ul class="store-ul"></ul>'), 0)
Assert.is_nil(Mapper.storeNode("sz=0&cookie=secret"))
Assert.is_nil(Mapper.storeNode("sz=0&sz=2"))
Assert.is_nil(Mapper.storeNode("../../myself"))
Assert.eq(Mapper.storeNode("sz=0&fc=34%2C102"), "fc=34%2C102&sz=0")

local requests, delayed, failed = {}, false, false
package.loaded["http.request"] = {
    get = function(url, options, cb)
        local request = { url = url, options = options, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        local page = tonumber(url:match("page=(%d+)"))
        if delayed and page == 2 then return handle end
        if failed and page == 2 then cb(nil, "network down"); return handle end
        cb(pageHtml(page, page < 3))
        return handle
    end,
}
local source = require("source.shuqi").new()
local result, reason
source:browseAsync({ limit = 60 }, function(value, err) result, reason = value, err end)
Assert.is_nil(reason)
Assert.len(result.data, 60)
Assert.eq(result.data[21].stable_id, "21")
Assert.is_nil(requests[1].options.headers.Cookie)
Assert.matches(requests[3].url, "page=3$")
requests = {}
source:browseAsync({ node = "都市", limit = 20 }, function(value) result = value end)
Assert.matches(requests[2].url, "fc=7")
Assert.len(result.data, 20)

failed = true
source:browseAsync({}, function(value, err) result, reason = value, err end)
Assert.is_nil(result)
Assert.eq(reason, "network down")
failed, delayed = false, true
local calls = 0
local handle = source:browseAsync({}, function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(requests[#requests].cancelled, "同步第一页回调不能覆盖第二页句柄")
requests[#requests].cb(pageHtml(2, true))
Assert.eq(calls, 0)
