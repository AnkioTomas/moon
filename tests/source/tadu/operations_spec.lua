--[[--
塔读书架回读确认、分页失效、取消与失效账号的退出入口。

@module tests.source.tadu.operations_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg = { cookie = "session=old", logged_in = true }
package.loaded["utils.settings"] = {
    getSource = function() return cfg end, saveSource = function() end,
}
local mode, requests, invalidated = "missing", {}, false
package.loaded["source.auth"] = {
    expired = function() return invalidated end,
    expire = function(_id, msg) invalidated = true; return msg end,
}
local row = '<title>个人中心</title><a data-bookid="9"></a><a class="linkBlock">测试书</a>'
package.loaded["http.request"] = {
    get = function(url, options, cb)
        local request = { url = url, options = options, cb = cb }
        requests[#requests + 1] = request
        local handle = { cancel = function() request.cancelled = true end }
        if url:find("/favorite/", 1, true) then cb(JSON.encode({ status = 200 })); return handle end
        if mode == "delayed" then return handle end
        if mode == "expired" and url:find("pgNum=2", 1, true) then
            cb("<title>免费阅读最新热门小说</title>")
        elseif mode == "expired" then
            cb(row .. '<a href="?pgNum=2">下一页</a>')
        elseif mode == "missing" then
            cb('<title>个人中心</title><div class="bookrack_table_kong"></div>')
        else
            cb(row)
        end
        return handle
    end,
    post = function(_url, _body, _options, cb)
        cb(JSON.encode({ status = 200 }))
        return { cancel = function() end }
    end,
}
local Client = require("source.tadu.client")
local result, reason
Client.addAsync("9", function(ok, err) result, reason = ok, err end)
Assert.is_nil(result, "200 但回读没有书不能清脏")
Assert.eq(reason, "塔读书架修改未确认，请稍后重试")
mode = "present"
Client.removeAsync("9", function(ok, err) result, reason = ok, err end)
Assert.is_nil(result, "删除200但仍在书架不能撕墓碑")
mode = "expired"
Client.shelfAsync(function(ok, err) result, reason = ok, err end)
Assert.is_nil(result, "第二页失效不能返回第一页当全量快照")
Assert.is_true(invalidated)
Assert.eq(cfg.cookie, "session=old")
Assert.is_true(not Client.loggedIn())
Assert.eq(requests[#requests].options.cache_ttl, 0)

mode = "delayed"
local calls = 0
local handle = Client.addAsync("9", function() calls = calls + 1 end)
handle:cancel()
Assert.is_true(requests[#requests].cancelled)
requests[#requests].cb(row)
Assert.eq(calls, 0)

package.loaded["ui.themes.widgets.row"] = { widget = function(spec) return spec end }
local Setting = require("source.tadu.setting")
Assert.len(Setting.rows(), 4, "已失效账号仍必须能退出，否则无法导入新Cookie")
local cookie = require("source.cookie_login").fromPayload({ cookies = {
    { domain = ".tadu.com", name = "parent", value = "a" },
    { domain = "www.tadu.com", name = "host", value = "b" },
    { domain = "evil.test", name = "evil", value = "c" },
} }, "tadu.com")
Assert.eq(cookie, "host=b; parent=a")
