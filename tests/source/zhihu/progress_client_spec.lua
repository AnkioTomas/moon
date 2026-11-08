--[[--
知乎云进度协议：长篇最近章节、章内比例、毫秒时间与明确成功确认。

@module tests.source.zhihu.progress_client_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
package.loaded["json"] = JSON
local Stubs = require("support.stubs")
local cfg = require("utils.settings").getSource("zhihu")
cfg.cookie = "z_c0=progress-fixture"
local pending, sync_column = {}, false
local function request(url, options, cb, body)
    if sync_column and url:find("?is_new_column=", 1, true) then
        cb(JSON.encode({ last_learned_section_id = "3" }))
        return { cancel = function() error("已完成的详情请求不能覆盖在途正文请求") end }
    end
    local item = { url = url, options = options, cb = cb, body = body }
    pending[#pending + 1] = item
    return { cancel = function() item.cancelled = true end }
end
package.loaded["http.request"] = {
    get = request,
    post = function(url, body, options, cb) return request(url, options, cb, body) end,
}
local Client = require("source.zhihu.client")
local result, err, meta, calls
calls = 0
local function done(value, reason, info) result, err, meta, calls = value, reason, info, calls + 1 end
local function wire(id, fraction)
    return { id = id, cli_progress = { unit_progress = {
        unit_id = id, progress = fraction, client_updated_at = 1800000000123, is_finished = false,
    } } }
end
Client.progressAsync("1/2", done)
Assert.matches(pending[#pending].url, "/paid_columns/1/sections/2/manuscript%?v=1&manuscript_version=0$")
Assert.eq(pending[#pending].options.headers.Cookie, cfg.cookie)
pending[#pending].cb(JSON.encode(wire("2", .4)))
Assert.eq(result.fraction, .4)
Assert.eq(result.section_id, "2")
Assert.eq(result.updated_at, 1800000000)

Client.progressAsync("1/2", done)
pending[#pending].cb(JSON.encode(wire("2")))
Assert.is_nil(result)
Assert.is_true(meta.empty, "仅 unit_id、无进度值不算读过")
Client.progressAsync("1/2", done)
local finished = wire("2")
finished.cli_progress.unit_progress.is_finished = true
pending[#pending].cb(JSON.encode(finished))
Assert.eq(result.fraction, 1)

for _idx, bad in ipairs({ wire("9", .2), wire("2", 20), wire("2", "invalid"), {} }) do
    Client.progressAsync("1/2", done)
    pending[#pending].cb(JSON.encode(bad))
    Assert.is_nil(result)
    Assert.not_nil(err, "不合法的响应不能冒充云端无记录")
    Assert.is_nil(meta)
end
Client.progressAsync("1", done)
pending[#pending].cb(JSON.encode({ last_learned_section_id = "3" }))
Assert.matches(pending[#pending].url, "/sections/3/manuscript%?")
pending[#pending].cb(JSON.encode(wire("3")))
Assert.eq(result.fraction, 0, "长篇已知最近章节、没有章内比例时落在该章开头")
Assert.eq(result.section_id, "3")
Client.progressAsync("1", done)
pending[#pending].cb(JSON.encode({ last_learned_section_id = "0" }))
Assert.is_true(meta.empty)

sync_column = true
local job = Client.progressAsync("1", done)
local before = calls
job.cancel()
Assert.is_true(pending[#pending].cancelled)
pending[#pending].cb(JSON.encode(wire("3", .7)))
Assert.eq(calls, before, "取消后迟到结果不能交付")
sync_column = false

Client.putProgressAsync("2", .4, done)
local post = pending[#pending]
Assert.eq(post.url, "https://api.zhihu.com/promus/progress")
Assert.eq(post.options.headers.Cookie, cfg.cookie)
local sent = JSON.decode(post.body)[1]
Assert.eq(sent.unit_id, "2")
Assert.eq(sent.type, "paid_column")
Assert.eq(sent.progress, .4)
Assert.is_false(sent.is_finished)
Assert.eq(sent.client_updated_at % 1000, 0)
post.cb('{"success":true}', nil, { code = 200 })
Assert.is_true(result)
Client.putProgressAsync("2", 1, done)
Assert.is_true(JSON.decode(pending[#pending].body)[1].is_finished)
for _idx, body in ipairs({ "{}", '{"success":false}', '{"error":{"code":1}}', "not json" }) do
    pending[#pending].cb(body, nil, { code = 200 })
    Assert.is_nil(result)
    Assert.not_nil(err, "HTTP 200 不等于进度已确认")
end
Client.putProgressAsync("2", .4, done)
pending[#pending].cb(nil, "network failed")
Assert.eq(err, "network failed")
local Auth = require("source.auth")
Auth.reset()
Client.putProgressAsync("2", .4, done)
pending[#pending].cb(nil, "HTTP 401", { code = 401 })
Assert.is_true(Auth.expired("zhihu"))
Auth.reset()
cfg.cookie = nil
local count = #pending
Client.progressAsync("1/2", done)
Stubs.flush()
Assert.eq(#pending, count)
Assert.eq(err, "请先登录知乎")
