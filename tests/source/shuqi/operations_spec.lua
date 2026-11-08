--[[--
书旗写入必须回读确认，取消和换号不能污染旧登录。

@module tests.source.shuqi.operations_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Stubs = require("support.stubs")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local cfg = { logged_in = true, token = "old", user_id = "7" }
package.loaded["utils.settings"] = { getSource = function() return cfg end, saveSource = function() end }
local requests, delayed, rows = {}, false, {}
package.loaded["http.request"] = {
    post = function(url, body, _opts, cb)
        local request = { cb = cb, url = url, body = body }
        requests[#requests + 1] = request
        if not delayed then cb(JSON.encode({ detail = rows })) end
        return { cancel = function() request.cancelled = true end }
    end,
}
local Client = require("source.shuqi.client")
local result, reason
Client.removeAsync("9", function(ok, err) result, reason = ok, err end)
Assert.is_true(result)
Assert.len(requests, 2, "写后另拉书架")
rows = { { bid = 9, chapterid = 11, percent = 0.5 } }
Client.removeAsync("9", function(ok, err) result, reason = ok, err end)
Assert.is_nil(result)
Assert.eq(reason, "同步结果未确认，请重试")
Client.putProgressAsync("9", "12", "", 0.5, function(ok, err) result, reason = ok, err end)
Assert.is_nil(result)
Assert.eq(reason, "同步结果未确认，请重试")
Client.putProgressAsync("9", "11", "", 0.5, function(ok, err) result, reason = ok, err end)
Assert.is_true(result)

rows[1].percent = 0.168
local write_index = #requests + 1
Client.putProgressAsync("9", "11", "", 0.1676, function(ok, err) result, reason = ok, err end)
Assert.is_true(result, "服务端三位小数舍入不能误判为上传失败")
local data = JSON.decode(require("utils.text").urlDecode(requests[write_index].body:match("data=([^&]*)")))
local mark = data.bookmark[1]
Assert.eq(type(mark.last_update), "string")
Assert.eq(tonumber(mark.last_update) * 1000, mark.add_time, "last_update 为秒，add_time 为毫秒")
Client.putProgressAsync("9", "11", "", 0.1675, function(ok, err) result, reason = ok, err end)
Assert.is_true(result, "三位小数半单位舍入边界")
Client.putProgressAsync("9", "11", "", 0.1674, function(ok, err) result, reason = ok, err end)
Assert.is_nil(result, "超出服务端舍入误差仍必须失败")
Assert.eq(reason, "同步结果未确认，请重试")
Client.putProgressAsync("9", "12", "", 0.1676, function(ok, err) result, reason = ok, err end)
Assert.is_nil(result, "比例匹配不能掩盖章节不匹配")

local count = 0
local read_count = 0
package.loaded["http.request"].post = function(_url, _body, _opts, cb)
    read_count = read_count + 1
    local request = { cb = cb }
    requests[#requests + 1] = request
    if read_count == 1 then cb(JSON.encode({ detail = rows })) end
    return { cancel = function() request.cancelled = true end }
end
local handle = Client.removeAsync("9", function() count = count + 1 end)
handle:cancel()
Assert.is_true(requests[#requests].cancelled)
requests[#requests].cb(JSON.encode({ detail = {} }))
Assert.eq(count, 0)

delayed = true
package.loaded["http.request"].post = function(_url, _body, options, cb)
    local request = { cb = cb, options = options }
    requests[#requests + 1] = request
    return { cancel = function() request.cancelled = true end }
end

local before = #requests
local completed = 0
Client.shelfAsync(function(books) if books then completed = completed + 1 end end)
local cancelled = Client.shelfAsync(function() completed = completed + 10 end)
Client.load()
Client.progressAsync("9", function(pos) if pos then completed = completed + 1 end end)
Assert.len(requests, before + 1, "刷新与进度读取不能同时发书签请求，重新载入同账号也不能拆队列")
cancelled:cancel()
Assert.is_nil(requests[before + 1].cancelled, "取消排队请求不能取消正在执行的请求")
requests[before + 1].cb(JSON.encode({ detail = rows }))
Assert.eq(completed, 1)
Stubs.flush()
Assert.len(requests, before + 2, "取消的排队请求不得发网络请求")
requests[before + 2].cb(JSON.encode({ detail = rows }))
Assert.eq(completed, 2)

before = #requests
completed = 0
local active = Client.shelfAsync(function() completed = completed + 10 end)
local waiting = Client.shelfAsync(function() completed = completed + 10 end)
Client.shelfAsync(function(books) if books then completed = completed + 1 end end)
active:cancel()
Assert.is_true(requests[before + 1].cancelled)
waiting:cancel()
Stubs.flush()
Assert.len(requests, before + 2, "取消正在执行和即将执行的请求后，后续请求仍能继续")
requests[before + 1].cb(JSON.encode({ detail = rows }))
Assert.eq(completed, 0, "忽略已取消请求的迟到回调")
requests[before + 2].cb(JSON.encode({ detail = rows }))
Assert.eq(completed, 1)

before = #requests
Client.shelfAsync(function(books, err) result, reason = books, err end)
Client.shelfAsync(function(books) if books then completed = completed + 1 end end)
requests[before + 1].cb(JSON.encode({ status = 10006, message = "未知状态码错误" }))
Assert.is_nil(result)
Assert.eq(reason, "未知状态码错误 (10006)", "业务错误保留原提示和状态码")
Stubs.flush()
Assert.len(requests, before + 2, "失败必须释放接口，不能把后续刷新挂死")
requests[before + 2].cb(JSON.encode({ detail = rows }))
Assert.eq(completed, 2)

before = #requests
local changed = 0
local function onChanged(books, err)
    if not books and err == "登录状态已变化，请重试" then changed = changed + 1 end
end
Client.shelfAsync(onChanged)
Client.shelfAsync(onChanged)
Client.reset()
requests[before + 1].cb(JSON.encode({ detail = rows }))
Stubs.flush()
Assert.len(requests, before + 1, "账号失效后，旧会话排队请求不得再发出")
Assert.eq(changed, 2)

local function session(id)
    return JSON.encode({ status = 200, data = { token = "new", userInfo = { userid = id } } })
end
package.loaded["source.logout"] = { clear = function(_id, clear) clear(); return true end }
Client.sendCodeAsync("13800138000", "captcha", function() end, { user_agent = "Test-UA" })
Assert.eq(requests[#requests].options.headers["User-Agent"], "Test-UA")
Client.loginAsync("13800138000", "code", { user_agent = "Test-UA" }, function(ok, err) result, reason = ok, err end)
Assert.eq(requests[#requests].options.headers["User-Agent"], "Test-UA")
requests[#requests].cb(session(8))
Assert.is_true(result ~= nil)
Assert.eq(cfg.token, "new")
Assert.eq(cfg.user_id, "8")
Assert.is_nil(reason)

local login = Client.loginAsync("13800138000", "code", nil, function() count = count + 1 end)
login:cancel()
requests[#requests].cb(session(7))
Assert.eq(cfg.token, "new")
Assert.eq(count, 0)

Client.loginAsync("13800138000", "code", nil, function(ok, err) result, reason = ok, err end)
local late = requests[#requests]
Client.reset()
late.cb(session(7))
Assert.is_nil(result)
Assert.eq(reason, "登录状态已变化，请重试")
Assert.eq(cfg.token, "new")
Client.loginAsync("13800138000", "code", nil, function(ok) result = ok end)
requests[#requests].cb(session(7))
Assert.eq(cfg.token, "new", "同账号续期允许替换令牌")
Client.loginAsync("13800138000", "code", nil, function(ok, err) result, reason = ok, err end)
requests[#requests].cb("<html>verification required</html>")
Assert.is_nil(result)
Assert.matches(reason, "安全验证")
Assert.eq(cfg.token, "new")
Client.loginAsync("13800138000", "code", nil, function(ok, err) result, reason = ok, err end)
requests[#requests].cb(JSON.encode({ status = 10003 }))
Assert.eq(reason, "书旗登录失败（状态：10003）")
