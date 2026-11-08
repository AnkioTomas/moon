--[[--
爱看书动态分类、完本首页错链、聚合分页与取消。

@module tests.source.18ta.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Mapper = require("source.18ta.mapper")
local filters = [[<div id="after_menu"><div>只看全本</div><div>
<a href="/sort/">全部分类</a><a href="/sort/1/1.html">玄幻奇幻</a>
<a href="/sort/42/1.html">新增分类</a></div></div>]]
local groups = Mapper.storeGroups(filters, "/quanben/sort/1/1.html")
Assert.len(groups, 2)
Assert.eq(groups[1].chips[3].id, "/quanben/sort/42/1.html", "分类取官网，不硬编码ID")
Assert.eq(groups[2].chips[1].id, "/sort/1/1.html", "切状态保留分类")
Assert.is_nil(Mapper.storeGroups("<html>维护</html>", "/sort/"))
Assert.is_nil(Mapper.storeNode("/sort/../../account"))
Assert.is_nil(Mapper.storeNode("//evil.test/sort/"))
Assert.eq(Mapper.storePage("/quanben/sort/", 2), "/quanben/sort/2.html")
Assert.is_true(Mapper.storeMore('<div id="pagelink"><a href="/sort/1/2.html">2</a></div>', "/quanben/sort/1/1.html", 1))
Assert.is_false(Mapper.storeMore('<a href="/sort/1/2.html">推荐链接</a>', "/sort/1/1.html", 1))

local requests, delayed, failed, malformed = {}, false, false, false
package.loaded["http.request"] = {
    headerAll = function() return {} end,
    get = function(url, _opts, cb)
        local request = { url = url, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        local page = tonumber(url:match("/(%d+)%.html$")) or 1
        if delayed and page == 2 then return handle end
        if failed and page == 2 then cb(nil, "network down"); return handle end
        if malformed then cb("<title>维护</title>"); return handle end
        local cards = {}
        for index = 1, 30 do
            local id = (page - 1) * 30 + index
            cards[#cards + 1] = '<li><div class="img_span"><a href="/akshtml' .. id
                .. '.html"><h2>书' .. id .. '</h2><span>玄幻 / 全本</span></a></div></li>'
        end
        cb(filters .. '<ul class="flex">' .. table.concat(cards) .. '</ul><div id="pagelink">'
            .. (page < 3 and '<a href="/sort/1/' .. (page + 1) .. '.html">下一页</a>' or "") .. '</div>')
        return handle
    end,
}
local source = require("source.18ta").new()
local result, reason
source:browseAsync({ node = "/quanben/sort/1/1.html" }, function(data, err) result, reason = data, err end)
Assert.is_nil(reason)
Assert.len(result.data, 60)
Assert.eq(requests[2].url, "https://www.18ta.com/quanben/sort/1/2.html")
Assert.eq(result.groups[1].active, "/quanben/sort/1/1.html")
source:browseAsync({ node = "1", limit = 8 }, function(data, err) result, reason = data, err end)
Assert.len(result.data, 8)
Assert.eq(requests[#requests].url, "https://www.18ta.com/sort/1/1.html", "旧数字节点保持兼容")
Assert.is_false(source:capabilities().shelf_push)

failed = true
source:browseAsync({ node = "1" }, function(data, err) result, reason = data, err end)
Assert.is_nil(result)
Assert.eq(reason, "network down")
failed, malformed = false, true
source:browseAsync({}, function(data, err) result, reason = data, err end)
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
malformed, delayed = false, true
local calls = 0
local handle = source:browseAsync({ node = "1" }, function() calls = calls + 1 end)
handle.cancel()
Assert.is_true(requests[#requests].cancelled, "同步第一页不能覆盖第二页句柄")
requests[#requests].cb(filters)
Assert.eq(calls, 0)
