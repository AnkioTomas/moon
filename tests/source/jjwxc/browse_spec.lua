--[[--
晋江动态分类：真实 HTML 形状、筛选、分页、旧榜单、错误与取消。

@module tests.source.jjwxc.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Mapper = require("source.jjwxc.mapper")
local html = [[<form id="wap_bookbase_form">
<label><input type='checkbox' name='xx0' value="0"/>不限</label>
<label><input type='checkbox' name='xx2' value="2"/>纯爱</label>
<label><input name='yc0' value="0"/>不限</label><label><input name='yc1' value="1"/>原创</label>
<label><input name='sd0' value="0"/>不限</label><label><input name='sd2' value="2"/>古色古香</label>
<label><input name='lx0' value="0"/>不限</label><label><input name='lx1' value="1"/>爱情</label>
<label><input name='fw0' value="0"/>全站</label><label><input name='fw6' value="6"/>免费</label>
</form><select name="sortType"><option value="2">积分</option><option value="1">最近更新</option></select>
<select name="isfinish"><option value="0" selected>无限制
<option value="1">连载</option><option value="2">完结</option></select>
<table width="100%"><tr><td>《<a class="track" href="/book2/101">甲&amp;乙</a>》 ---
<a href="/wapauthor/8">测试作者</a></td></tr></table>
<div id='pageArea'>共3页，当前第1页</div>]]
local parsed = Mapper.category(html)
Assert.eq(parsed.filters.xx[2].id, "2")
Assert.eq(parsed.filters.isfinish[1].title, "无限制")
Assert.eq(parsed.books[1].title, "甲&乙")
Assert.eq(parsed.books[1].authors, "测试作者")
Assert.eq(parsed.pages, 3)
Assert.matches(parsed.books[1].cover, "novelid=101$")
Assert.is_nil(Mapper.category("<html>错误</html>"))
Assert.len(Mapper.category(html:gsub("<tr>.-</tr>", "")).books, 0)

local requests, reply, mode = {}, nil, "pending"
package.loaded["source.jjwxc.client"] = {
    categoryAsync = function(params, cb)
        local saved = {}
        for key, value in pairs(params) do saved[key] = value end
        local request = { params = saved, cb = cb, cancelled = false }
        request.cancel = function() request.cancelled = true end
        requests[#requests + 1] = request
        if #requests == 1 then cb(Mapper.category(html))
        elseif mode == "oversized" then
            cb({ page = params.page, pages = 3, books = {
                { source_id = "jjwxc", stable_id = "201" },
                { source_id = "jjwxc", stable_id = "202" },
                { source_id = "jjwxc", stable_id = "203" },
            } })
        elseif mode == "sync" then
            cb({ page = params.page, pages = 3, books = { { source_id = "jjwxc", stable_id = tostring(params.page) } } })
        end
        return request
    end,
    storeHomeAsync = function(cb) cb({}); return { cancel = function() end } end,
}
package.loaded["source.jjwxc.browse"] = nil
local Library = require("source.jjwxc.browse")
local handle = Library.run({}, function(value) reply = value end)
Assert.eq(requests[2].params.page, 2)
handle.cancel()
Assert.is_true(requests[2].cancelled)
requests[2].cb({ page = 2, pages = 3, books = {} })
Assert.is_nil(reply)

requests, mode = {}, "sync"
Library.run({ limit = 2 }, function(value) reply = value end)
Assert.len(reply.data, 2)
Assert.eq(reply.groups[1].title, "频道")
Assert.eq(reply.groups[1].chips[2].id, "cate:2:0:0:0:0:0:2")
Assert.eq(reply.groups[5].chips[2].id, "cate:0:0:0:0:6:0:2")
Assert.is_true(reply.more)

requests = {}
Library.run({ limit = 1 }, function(value) reply = value end)
Assert.len(reply.data, 1)
Assert.is_true(reply.more)

requests, mode = {}, "oversized"
Library.run({ limit = 2 }, function(value) reply = value end)
Assert.len(reply.data, 2, "聚合整页超过 limit 时只交付要求数量")
Assert.eq(reply.data[2].stable_id, "201")
Assert.is_true(reply.more)
Assert.len(requests, 2)

requests, mode = {}, "pending"
local reason
Library.run({}, function(value, err) reply, reason = value, err end)
requests[2].cb(nil, "网络故障")
Assert.is_nil(reply)
Assert.eq(reason, "网络故障")

requests = {}
Library.run({}, function(value, err) reply, reason = value, err end)
requests[2].cb({ page = 1, pages = 3, books = {} })
Assert.is_nil(reply)
Assert.eq(reason, "晋江分类响应无效")

requests = {}
Library.run({ node = "cate:99:0:0:0:0:0:2" }, function(value, err) reply, reason = value, err end)
Assert.is_nil(reply)
Assert.eq(reason, "晋江分类条件无效")

package.loaded["source.jjwxc"] = nil
local source = require("source.jjwxc").new()
source:browseAsync({ node = "1:1" }, function(value, err) reply, reason = value, err end)
Assert.is_nil(reply)
Assert.eq(reason, "晋江榜单无法解析", "旧榜单节点仍走榜单")
