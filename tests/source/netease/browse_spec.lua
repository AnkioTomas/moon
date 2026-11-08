--[[--
网易官网分类：频道、筛选、带封面的分页结果与取消。

@module tests.source.netease.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Mapper = require("source.netease.mapper")
local html = [[
<a href="/category/original.do?gender=male&amp;id=7">都市</a>
<a href="/category/original.do?gender=female&amp;id=8">现言</a>
<a href="/category/publish.do?id=2000">小说作品</a>
<a href="/category/publish.do?id=2000">重复链接</a>
<a href="/category/publish.do?id=2300">人文社科</a>
]]
local categories = Mapper.categories(html)
Assert.len(categories.male, 1)
Assert.eq(categories.female[1].id, "8")
Assert.len(categories.publish, 2)
Assert.eq(categories.publish[2].title, "人文社科")
Assert.is_nil(Mapper.categories("<html>网站维护</html>"))
Assert.is_nil(Mapper.catalog({ code = 0, data = { books = {} } }), "缺失分页字段不能当成功空书城")

local requests, failure_page, delayed = {}, nil, false
package.loaded["http.request"] = {
    get = function(url, opts, cb)
        local request = { url = url, opts = opts, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        if url:match("/category$") then cb(html); return handle end
        if delayed then return handle end
        local page = tonumber(url:match("[?&]page=(%d+)"))
        if page == failure_page then cb(nil, "network down"); return handle end
        local books = {}
        for i = 1, 20 do
            books[i] = { sourceUrl = "/source/book_" .. page .. "_" .. i, title = "书 " .. i,
                iconUrl = "//img/book.jpg", author = "作者" }
        end
        cb(JSON.encode({ code = 0, data = { books = books, pageQuery = { more = page < 3 } } }))
        return handle
    end,
}
local source = require("source.netease").new()
local result, err
source:browseAsync({ node = "female:8:new:1:2", limit = 40 }, function(value, reason) result, err = value, reason end)
Assert.is_nil(err)
Assert.len(result.data, 40)
Assert.eq(result.data[1].cover, "https://img/book.jpg")
Assert.eq(result.data[21].stable_id, "book_2_1")
Assert.len(result.groups, 5)
Assert.eq(result.groups[1].active, "female:all:new:1:0", "切分类后仍须标亮当前频道")
Assert.eq(result.groups[2].active, "female:8:new:1:2")
Assert.eq(result.groups[1].chips[1].id, "male:all:new:1:0", "换频道清分类与完结状态，保留排序和资费")
Assert.eq(result.groups[3].title, "排序")
Assert.matches(requests[2].url, "/category/original/data%.json%?")
Assert.matches(requests[2].url, "gender=female")
Assert.matches(requests[2].url, "sort=1")
Assert.matches(requests[2].url, "pay=1")
Assert.matches(requests[2].url, "state=2")
Assert.is_nil(requests[2].opts.headers, "公开分类不能携带电脑端 Cookie")
Assert.matches(requests[3].url, "page=2")
source:browseAsync({ node = "publish:2300:hot:0:0" }, function(value, reason) result, err = value, reason end)
Assert.len(result.data, 60, "不是只取榜单第一页的十几本")
Assert.len(result.groups, 4)
Assert.matches(requests[#requests].url, "/category/publish/data%.json%?")
Assert.matches(requests[#requests].url, "sort=1", "出版和原创的排序编码相反")
Assert.matches(requests[#requests].url, "id=2300")
Assert.is_nil(requests[#requests].url:find("state=", 1, true))
source:browseAsync({ node = "male:999:new:0:0", limit = 20 }, function(value) result = value end)
Assert.eq(result.groups[2].active, "male:all:new:0:0", "分类已下线时回到全部分类")
Assert.matches(requests[#requests].url, "id=&")
source:browseAsync({ node = "female", limit = 20 }, function(value) result = value end)
Assert.eq(result.groups[1].active, "female:all:hot:0:0", "旧频道节点继续可用")
failure_page = 2
source:browseAsync({}, function(value, reason) result, err = value, reason end)
Assert.is_nil(result, "第二页失败不能缓存第一页面冒充完整结果")
Assert.eq(err, "network down")
failure_page, delayed = nil, true
local handle = source:browseAsync({}, function(value) result = value end)
handle:cancel()
Assert.is_true(requests[#requests].cancelled, "分类页同步命中后，必须取消在飞的列表而不是分类请求")
