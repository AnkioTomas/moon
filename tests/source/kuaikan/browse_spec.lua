--[[--
快看分类：官网动态题材、独立筛选、聚合分页与取消。

@module tests.source.kuaikan.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch, inject-field

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded.json = JSON
local Mapper = require("source.kuaikan.mapper")
local Request = require("http.request")
local calls, waiting, cancelled = {}, nil, {}
local failure
local function wire(page)
    local rows = {}
    for index = 1, page == 1 and 48 or 47 do
        rows[index] = {
            id = (page - 1) * 48 + index, title = "漫画 " .. index,
            author_name = "作者", vertical_image_url = "https://img/cover.jpg",
        }
    end
    return {
        code = 200, total = 200,
        hits = { topicCategories = { { tag_id = 0, title = "全部" }, { tagId = 20, title = "恋爱" } },
            topicMessageList = rows },
    }
end
Request.get = function(url, options, cb)
    calls[#calls + 1] = url
    Assert.is_nil(options.headers.Cookie)
    local page = tonumber(url:match("page=(%d+)"))
    if page == 2 and waiting then
        waiting = cb
        return { cancel = function() cancelled[page] = true end }
    end
    cb(page == 2 and failure or JSON.encode(wire(page)))
    return { cancel = function() cancelled[page] = true end }
end
local Client = require("source.kuaikan.client")
local source = require("source.kuaikan").new()
local result, reason
source:browseAsync({ limit = 60 }, function(res, err) result, reason = res, err end)
Assert.is_nil(reason)
Assert.len(result.data, 60)
Assert.eq(result.data[49].stable_id, "49")
Assert.eq(result.data[1].authors, "作者")
Assert.len(calls, 2)
Assert.len(result.groups, 5)
Assert.eq(result.groups[1].chips[2].id, "20:1:0:0:1")

local node = "20:3:2:1:2"
local list, groups, more = Mapper.store(wire(2), node, 2)
Assert.len(list, 47)
Assert.is_true(more)
Assert.eq(groups[1].active, node)
Assert.eq(groups[1].chips[1].id, "0:3:2:1:2")
Assert.eq(groups[2].chips[2].id, "20:2:2:1:2")
Assert.eq(groups[3].chips[2].id, "20:3:1:1:2")
Assert.eq(groups[4].chips[3].id, "20:3:2:2:2")
Assert.eq(groups[5].chips[3].id, "20:3:2:1:3")
source:browseAsync({ node = node, limit = 12 }, function(res) result = res end)
Assert.len(result.data, 12)
Assert.matches(calls[#calls], "tag_id=20")
Assert.matches(calls[#calls], "label_dimension_origin=3")
Assert.matches(calls[#calls], "pay_status=2")
Assert.matches(calls[#calls], "update_status=1")
Assert.matches(calls[#calls], "sort=2")

local terminal = wire(3)
terminal.total = 100
Assert.is_false(select(3, Mapper.store(terminal, node, 3)))
terminal.hits.topicMessageList = {}
Assert.len(Mapper.store(terminal, node, 3), 0)
terminal.hits.topicMessageList = { { id = 1 } }
Assert.is_nil(Mapper.store(terminal, node, 3))
Assert.is_nil(Mapper.store({ code = 200, hits = {} }, node, 1))
Assert.eq(Mapper.storeNode("20:9:0:0:1"), "0:1:0:0:1")
Assert.eq(Mapper.storeNode("旧热门榜单"), "0:1:0:0:1")

failure = JSON.encode({ code = 500 })
result, reason = nil, nil
source:browseAsync({ limit = 60 }, function(res, err) result, reason = res, err end)
Assert.is_nil(result)
Assert.is_true(reason ~= nil)
failure = nil
waiting = true
local called = false
local handle = source:browseAsync({ limit = 60 }, function() called = true end)
handle.cancel()
Assert.is_true(cancelled[2])
Assert.is_nil(cancelled[1])
waiting(JSON.encode(wire(2)))
Assert.is_false(called)

Request.get = function(_url, _options, cb)
    cb(nil, "network failure")
    return { cancel = function() end }
end
Client.storeAsync(node, 1, function(books, err)
    Assert.is_nil(books)
    Assert.eq(err, "network failure")
end)
