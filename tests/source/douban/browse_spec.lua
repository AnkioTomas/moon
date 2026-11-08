--[[--
豆瓣分类书城：动态分类、协议筛选、跨页聚合和取消。

@module tests.source.douban.browse_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Json = require("support.json_stub")
package.preload["json"] = function() return Json end
local Mapper = require("source.douban.mapper")
local tree = Json.encode({
    { id = 0, children = { { id = 505, name = "科幻小说", children = {} } } },
    { id = 1, children = { { id = 100, name = "小说", children = {
        { id = 116, name = "科幻", children = {} },
    } } } },
})
local cats = Mapper.categories("Ark.kindTree = " .. tree .. ";")
Assert.eq(cats.original[1].id, "505")
Assert.eq(cats.publish[2].id, "116")
Assert.is_nil(Mapper.categories("登录页面"))
Assert.is_nil(Mapper.categories("Ark.kindTree = [false]"))

local body = Mapper.catalogBody({ category = "505", sort = "new", pay = "free", state = "complete" }, 2)
Assert.eq(body.kind, 505)
Assert.eq(body.page, 2)
Assert.eq(body.minPrice, 0)
Assert.eq(body.maxPrice, 0)
Assert.eq(body.isFinished, true)
Assert.eq(body.variables.includePurchase, false)

local requests, delayed, fail_page = {}, false, nil
package.preload["utils.settings"] = function() return { getSource = function() return { cookie = "private=1" } end } end
package.preload["http.request"] = function()
    return {
        headerAll = function() return {} end,
        request = function(opts, cb)
            local record = { opts = opts }
            requests[#requests + 1] = record
            local wire
            if opts.method == "GET" then
                wire = "Ark.kindTree = " .. tree
            else
                local params = Json.decode(opts.body)
                record.params = params
                if params.page ~= fail_page then
                    local list = {}
                    for idx = 1, 20 do list[idx] = { id = (params.page - 1) * 20 + idx, title = "测试书" } end
                    wire = Json.encode({ list = list, total = 100 })
                end
            end
            record.reply = function()
                if wire then cb({ code = 200, body = wire }, nil) else cb(nil, "network failed") end
            end
            if not delayed or opts.method == "GET" then record.reply() end
            return { cancel = function() record.cancelled = true end }
        end,
    }
end
local source = require("source.douban").new()
local result
source:browseAsync({ node = "original:505:new:free:complete", limit = 60 }, function(value) result = value end)
Assert.eq(#result.data, 60)
Assert.eq(result.data[60].stable_id, "60")
Assert.eq(requests[2].params.kind, 505)
Assert.eq(requests[2].params.isFinished, true)
Assert.eq(result.groups[2].title, "分类")
Assert.eq(result.groups[2].active, "original:505:new:free:complete")
Assert.eq(result.groups[1].chips[2].id, "publish:1:hot:all:all")
for _idx, req in ipairs(requests) do Assert.is_nil(req.opts.headers.Cookie) end

source:browseAsync({ node = "publish:505:unknown:paid:serial", limit = 20 }, function(value) result = value end)
Assert.eq(requests[#requests].params.kind, 1)
Assert.eq(requests[#requests].params.sort, "hot")
Assert.eq(requests[#requests].params.minPrice, 1)
Assert.is_nil(requests[#requests].params.isFinished)
Assert.eq(#result.groups, 4)
source:browseAsync({ limit = 25 }, function(value) result = value end)
Assert.eq(#result.data, 25)

local err
fail_page = 2
source:browseAsync({ limit = 60 }, function(value, reason) result, err = value, reason end)
Assert.is_nil(result)
Assert.eq(err, "network failed")
fail_page, delayed = nil, true
local calls = 0
local job = source:browseAsync({}, function() calls = calls + 1 end)
local active = requests[#requests]
job.cancel()
Assert.is_true(active.cancelled)
active.reply()
Assert.eq(calls, 0)
