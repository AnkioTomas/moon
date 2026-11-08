--[[--
塔读官网分类、分页、坏响应与取消。

@module tests.source.tadu.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Mapper = require("source.tadu.mapper")
local root = "98-a-0-15-a-20-p-1-909"
local category = "99-a-0-15-a-20-p-1-909"
local filters = [[
<div class="lkLine"><span>频道</span>
<a href="/store/98-a-0-15-a-20-p-1-909" class="current">男频文创</a>
<a href="/store/122-a-0-15-a-20-p-1-122">女频</a>
<!--<a href="/store/79-a-0-15-a-20-p-1-79">出版</a>-->
</div>
<div class="lkLine"><span>分类</span><div>
<a href="/store/98-a-0-15-a-20-p-1-909" class="current">全部</a>
<a href="/store/99-a-0-15-a-20-p-1-909">东方玄幻</a>
</div></div>
<div class="lkLine" hidden=""><span>属性</span>
<a href="/store/98-a-0-15-a-20-p-1-909">全部</a></div>
<div class="tabList">
<div class="tab current"><span onclick="window.location.href='/store/98-a-0-15-a-20-p-1-909'">默认排序</span></div>
<a href="/store/98-a-0-12-a-20-p-1-909" class="tab">周人气</a>
<div class="rtIcon"></div></div>
]]
Assert.is_true(Mapper.storeNode(root))
Assert.is_true(not Mapper.storeNode("../../user/info"))
Assert.eq(Mapper.storePage(root, 2), "98-a-0-15-a-20-p-2-909")
local groups = Mapper.storeGroups(filters)
Assert.len(groups, 3)
Assert.len(groups[1].chips, 2, "注释里的出版不应展示")
Assert.eq(groups[2].title, "分类")
Assert.eq(groups[2].chips[2].id, category)
Assert.eq(groups[3].title, "排序")
Assert.eq(groups[3].active, root)
Assert.is_true(not Mapper.shelfHasNext('<a href="?pgNum=20">', 1))
Assert.is_nil(Mapper.listPage("<title>服务器维护</title>"))
Assert.len(Mapper.listPage('<ul class="bookList"></ul>'), 0)

local requests, delayed, failed = {}, false, false
package.loaded["http.request"] = {
    get = function(url, options, cb)
        local request = { url = url, options = options, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        local page = tonumber(url:match("%-p%-(%d+)%-")) or 1
        if delayed and page == 2 then return handle end
        if failed and page == 2 then cb(nil, "network down"); return handle end
        local cards = {}
        for index = 1, 20 do
            local id = (page - 1) * 20 + index
            cards[#cards + 1] = '<a href="/book/' .. id .. '/" class="bookImg"><img data-src="https://img.test/' .. id .. '.jpg"></a>'
                .. '<a href="/book/' .. id .. '/" class="bookNm">书' .. id .. '</a>'
                .. '<a class="bookIntro">简介</a><a class="authorNm"><i></i>作者</a>'
        end
        cb(filters .. table.concat(cards) .. (page < 3 and '<a href="/store/' .. Mapper.storePage(root, page + 1) .. '">下一页</a>' or ""))
        return handle
    end,
}
local source = require("source.tadu").new()
local result, reason
source:browseAsync({ limit = 60 }, function(value, err) result, reason = value, err end)
Assert.is_nil(reason)
Assert.len(result.data, 60)
Assert.eq(result.data[21].stable_id, "21")
Assert.eq(result.data[1].authors, "作者", "官网作者是 a，不是 div")
Assert.eq(result.data[1].cover, "https://img.test/1.jpg")
Assert.is_nil(requests[1].options.headers.Cookie)
Assert.matches(requests[3].url, "%-p%-3%-")

failed = true
source:browseAsync({}, function(value, err) result, reason = value, err end)
Assert.is_nil(result)
Assert.eq(reason, "network down", "后续页失败不能当第一页成功")
failed, delayed = false, true
local calls = 0
local handle = source:browseAsync({}, function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(requests[#requests].cancelled)
requests[#requests].cb(filters)
Assert.eq(calls, 0)
