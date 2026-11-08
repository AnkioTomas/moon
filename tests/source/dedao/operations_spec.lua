--[[--
得到多阶段请求：同步回调、取消、完整书架、账号归属与登录提交。

@module tests.source.dedao.operations_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local Json = require("support.json_stub")
local cfg = { cookie = "csrfToken=old; session=old", logged_in = true }
local fixtures, held, async, requests = {}, {}, {}, {}
local expired = 0
local warnings = {}
package.preload["utils.log"] = function()
    return { warn = function(...)
        local fields = {}
        for idx = 1, select("#", ...) do fields[idx] = tostring(select(idx, ...)) end
        warnings[#warnings + 1] = table.concat(fields, " ")
    end }
end

package.preload["json"] = function() return Json end
package.preload["utils.settings"] = function()
    return { getSource = function() return cfg end, saveSource = function() end }
end
package.preload["source.auth"] = function()
    return {
        ok = function() end,
        expire = function(_id, message) expired = expired + 1; return message end,
    }
end
package.preload["source.base"] = function()
    return { defer = function(done, ...)
        done(...)
        return { cancel = function() end }
    end }
end

local function wire(body)
    return Json.encode({ h = { c = 0 }, c = body })
end

local function request(url, body, options, done)
    local path = url:match("https://[^/]+([^?]+)")
    local item = { path = path, body = body and body ~= "" and Json.decode(body) or nil, options = options, done = done }
    requests[#requests + 1] = item
    if async[path] then
        held[path] = item
    else
        done(fixtures[path](item.body), nil, path == "/" and { cookies = { "csrfToken=candidate; Path=/" } } or {})
    end
    return { cancel = function() item.cancelled = true end }
end

package.preload["http.request"] = function()
    return {
        headerAll = function(res) return res.cookies or {} end,
        get = function(url, options, done) return request(url, nil, options, done) end,
        post = request,
    }
end

local Client = require("source.dedao.client")

local search_path = "/api/search/pc/tophits"
async[search_path] = true
local completed = false
local job = Client.searchAsync("test", function() completed = true end)
job.cancel()
Assert.is_true(held[search_path].cancelled)
held[search_path].done(wire({ data = { moduleList = {} } }), nil, {})
Assert.is_false(completed)

fixtures["/api/pc/ebook2/v1/pc/read/token"] = function(body)
    Assert.is_nil(body.ptype)
    return wire({ token = "test-token" })
end
local info_path = "/ebk_web/v1/get_book_info"
async[info_path] = true
completed = false
job = Client.bookInfoAsync("test-book", function() completed = true end)
job.cancel()
Assert.is_true(held[info_path].cancelled)
held[info_path].done(wire({ bookInfo = {} }), nil, {})
Assert.is_false(completed)

local oauth_path = "/loginapi/getAccessToken"
async[oauth_path] = true
completed = false
job = Client.accessTokenAsync(function() completed = true end)
job.cancel()
Assert.is_true(held[oauth_path].cancelled)
held[oauth_path].done('"test-oauth"', nil, {})
Assert.is_false(completed)

local shelf_path = "/api/hades/v2/product/list"
fixtures[shelf_path] = function(body)
    return wire({ list = { { enid = "book-" .. body.page, type = 2 } }, is_more = body.page < 44 })
end
local shelf, shelf_err
Client:shelfSyncAsync(function(body, err) shelf, shelf_err = body, err end)
Assert.len(shelf.list, 44)
Assert.is_false(shelf.is_more)
Assert.is_nil(shelf_err)

fixtures[shelf_path] = function() return wire({}) end
Client:shelfSyncAsync(function(body, err) shelf, shelf_err = body, err end)
Assert.is_nil(shelf)
Assert.eq(shelf_err, "响应无效")

fixtures[shelf_path] = function()
    return wire({ list = { { enid = "same", type = 2 } }, is_more = true })
end
Client:shelfSyncAsync(function(body, err) shelf, shelf_err = body, err end)
Assert.is_nil(shelf)
Assert.eq(shelf_err, "响应无效")

local progress_path = "/api/pc/ebook2/v1/pc/getread"
async[progress_path] = true
Client.progressAsync("test-book", function() end)
cfg.cookie = "csrfToken=new; session=new"
held[progress_path].done(Json.encode({ h = { c = 401, e = "expired old account" } }), nil,
    { cookies = { "session=stale; Path=/" } })
Assert.eq(expired, 0)
Assert.eq(cfg.cookie, "csrfToken=new; session=new")
Client.load()
Assert.matches(Client.cookie(), "session=new")

fixtures["/api/pc/user/info"] = function() return wire({ uid_hazy = "user-one" }) end
local logged, login_err
local candidate = { csrfToken = "candidate", session = "candidate-session" }
Client.confirmLoginAsync(candidate, function(ok, err) logged, login_err = ok, err end)
Assert.is_true(logged)
Assert.is_nil(login_err)
Assert.eq(cfg.uid, "user-one")
Assert.eq(cfg.cookie, "csrfToken=candidate; session=candidate-session")

fixtures["/api/pc/user/info"] = function() return wire({ uid_hazy = "user-two" }) end
Client.confirmLoginAsync({ session = "other" }, function(ok, err) logged, login_err = ok, err end)
Assert.is_nil(logged)
Assert.eq(login_err, "请先退出当前账号，再登录其他账号")
Assert.matches(cfg.cookie, "candidate%-session")

local review_path = "/pc/ebook2/v1/comment/list"
fixtures[review_path] = function(body)
    local list = {}
    for idx = 1, body.page == 1 and 20 or 3 do
        list[#list + 1] = { note_id_hazy = "note-" .. ((body.page - 1) * 20 + idx), note = "test" }
    end
    return wire({ list = list, total = 23 })
end
local reviews
Client.reviewsAsync("test-book", function(body) reviews = body end)
Assert.len(reviews.list, 23)
Assert.eq(reviews.total, 23)
Assert.eq(requests[#requests].body.page, 2)
Assert.eq(requests[#requests].body.ptype, 2)

fixtures[review_path] = function() return wire({ total = 1, list = {} }) end
Client.reviewsAsync("test-book", function(body, err) reviews = body; Assert.eq(err, "响应无效") end)
Assert.is_nil(reviews)

fixtures["/"] = function() return "<html></html>" end
async[oauth_path] = false
fixtures[oauth_path] = function() return '"sms-test-oauth"' end
local sms_path = "/oauth/api/embedded/auth_code/send"
fixtures[sms_path] = function(body)
    Assert.is_nil(body.captcha)
    return Json.encode({ errCode = 0, data = { needCaptcha = true, captchaId = "official-captcha" } })
end
local sms, sms_err, challenge
local account_cookie = cfg.cookie
Client.sendCodeAsync("13800000000", function(value, err, next_step) sms, sms_err, challenge = value, err, next_step end)
Assert.is_nil(sms, "需要滑块不能当作短信已发送")
Assert.is_nil(sms_err)
Assert.eq(challenge.captcha_id, "official-captcha")
Assert.eq(challenge.session.oauth, "sms-test-oauth")
Assert.eq(cfg.cookie, account_cookie, "候选验证不能替换当前账号")

fixtures[sms_path] = function(body)
    Assert.eq(body.phone, "13800000000")
    Assert.eq(body.captcha.captchaId, "official-captcha")
    Assert.eq(body.captcha.validate, "test-proof")
    return Json.encode({ errCode = 0, data = {} })
end
Client.sendSessionCodeAsync(challenge.session, { captchaId = challenge.captcha_id, validate = "test-proof" },
    function(ok, err) Assert.is_true(ok); Assert.is_nil(err) end)
Assert.eq(requests[#requests].options.headers["X-Oauth-Access-Token"], "sms-test-oauth")

fixtures[sms_path] = function() return Json.encode({ errCode = 0, data = { needCaptcha = true } }) end
Client.sendSessionCodeAsync(challenge.session, nil, function(ok, err)
    Assert.is_nil(ok)
    Assert.eq(err, "响应无效")
end)

local mapped = require("source.dedao.mapper").reviews({ list = {
    { note_id_hazy = "review", note = "", content = "", note_line = "<p>实际书评</p>",
        notes_owner = { name = "测试作者" }, extra = { score_str = "4.0" } },
} })
Assert.len(mapped, 1)
Assert.eq(mapped[1].text, "实际书评")
Assert.eq(mapped[1].grade, 4)

local failure, failure_err
Client.bookInfoAsync("test-book", function(value, err) failure, failure_err = value, err end)
local timeout_error = "Request timeout: https://www.dedao.cn/ebk_web/v1/get_book_info?token=private-proof"
held[info_path].done(nil, timeout_error, { code = 0 })
Assert.is_nil(failure)
Assert.eq(failure_err, timeout_error)
Assert.len(warnings, 1)
Assert.matches(warnings[1], "GET /ebk_web/v1/get_book_info timeout")
Assert.matches(warnings[1], "timeout_seconds")
Assert.is_nil(warnings[1]:find("token", 1, true), "失败日志不记录查询参数或原始错误里的凭证")
Assert.is_nil(warnings[1]:find("private-proof", 1, true))
