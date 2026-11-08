--[[--
iRead 同步回调下的取消、搜索轮询、坏响应及登录态隔离。

@module tests.source.iread.async_spec
--]]
---@diagnostic disable: undefined-field, missing-fields, param-type-mismatch

local Assert = require("support.assert")
local JSON = require("support.json_stub")
local Stubs = require("support.stubs")
local simple = {}
package.loaded.json = {
    decode = setmetatable({ simple = simple }, {
        __call = function(_decoder, raw, opts)
            local data = JSON.decode(raw)
            if opts ~= simple and raw:find('"intro":null', 1, true) then
                data.data[1].intro = function() end
            end
            return data
        end,
    }),
    encode = JSON.encode,
    util = { null = function() end },
}
local cfg = { token = "old-token" }
package.loaded["utils.settings"] = { getSource = function() return cfg end }
local requests, replies = {}, {}
package.loaded["http.request"] = {
    post = function(url, body, opts, cb)
        local request = { url = url, body = body, opts = opts, cb = cb }
        requests[#requests + 1] = request
        local reply = table.remove(replies, 1)
        if reply then cb(JSON.encode({ code = 200, data = reply }), nil, { cookies = { "sid=new; Path=/" } }) end
        return { cancel = function() request.cancelled = true end }
    end,
    headerAll = function(res) return res and res.cookies or {} end,
}
local Client = require("source.iread.client")
local Auth = require("source.auth")
local result, reason, calls
local function done(value, err) result, reason, calls = value, err, (calls or 0) + 1 end
local function reset()
    requests, replies, result, reason, calls = {}, {}, nil, nil, 0
    cfg.token, cfg.cookie = "old-token", nil
    Stubs.reset()
    Auth.reset()
end
local function reply(request, data, code)
    request.cb(JSON.encode({ code = code or 200, data = data }))
end

reset()
Client.shelfAsync(done)
requests[1].cb('{"code":200,"data":[{"name":"书","intro":null,"author":null}]}')
Assert.is_nil(result[1].intro, "LuaJSON 的 null 应解成 nil，不能把函数哨兵写进书籍元数据")

reset()
Client.exploreRulesAsync(done)
reply(requests[1], { { id = 1, bookSourceName = "测试书源", exploreUrl = { "bad" } } })
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Client.exploreRulesAsync(done)
reply(requests[2], { { id = 1, bookSourceName = "测试书源", exploreUrl = {
    { title = "分组", url = "" }, { title = "分类", url = "https://example.test?page={{page}}" },
} } })
Assert.len(result[1].exploreUrl, 2)

reset()
replies = { {} }
local handle = Client.shelfAsync(done)
local pending = requests[2]
Assert.matches(pending.url, "/user/home$")
handle:cancel()
Assert.is_true(pending.cancelled)
reply(pending, { nickname = "测试" })
Assert.eq(calls, 0)

reset()
replies = { {} }
Client.shelfAsync(done)
reply(requests[2], {})
Assert.is_nil(result)
Assert.eq(reason, "iRead 账号信息为空")
Assert.eq(calls, 1)

reset()
cfg.token = nil
replies = { { task = "guest-task" }, { result = { { name = "公开书" } }, remaining = 0 } }
Client.searchAsync("公开书", done)
Assert.len(result, 1)
Assert.is_nil(requests[1].opts.headers.Authorization)
Assert.is_nil(requests[1].opts.headers.Cookie)
Assert.eq(requests[1].opts.headers["X-Requested-With"], "XMLHttpRequest")
Client.userAsync({}, done)
reply(requests[3], {}, 401)
Assert.is_true(not Auth.expired("iread"), "游客未登录不能污染已有源的失效提示")

reset()
Client.shelfAsync(done)
cfg.token = "new-token"
reply(requests[1], {})
Assert.len(requests, 1, "旧书架回调不能拿新凭证校验空书架")
Assert.is_nil(result)
Assert.eq(reason, "登录状态已变化，请重试")

reset()
Auth.expire("iread", "expired")
Client.chaptersAsync({ name = "书" }, done)
reply(requests[1], { bad = true })
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Assert.is_true(Auth.expired("iread"), "坏响应不能清除失效标记")
Client.shelfAsync(done)
reply(requests[2], { { author = "缺少书名" } })
Assert.is_nil(result)
Assert.eq(reason, "响应无效")
Client.shelfAsync(done)
requests[3].cb(nil, "network failed")
Assert.eq(reason, "network failed")
Assert.eq(cfg.token, "old-token")

reset()
Client.shelfAsync(done)
cfg.token = "new-token"
reply(requests[1], {}, 401)
Assert.is_true(not Auth.expired("iread"), "旧凭证失败不能注销新凭证")
Assert.eq(reason, "登录状态已变化，请重试")

reset()
replies = { { task = "task-1" } }
handle = Client.searchAsync("书", done)
pending = requests[2]
handle:cancel()
Assert.is_true(pending.cancelled, "同步提交不能覆盖正在轮询的取消句柄")
reply(pending, { result = { { name = "书" } }, remaining = 0 })
Stubs.flush()
Assert.eq(calls, 0)

reset()
cfg.token, cfg.cookie = nil, "sid=old; login=test"
replies = { { task = "task-1" } }
Client.searchAsync("书", done)
Assert.eq(requests[2].opts.headers.Cookie, "login=test; sid=new")
Assert.is_nil(requests[2].opts.headers.Authorization)
reply(requests[2], { result = { { name = "书" } }, remaining = 1 })
Stubs.flush()
Assert.len(requests, 3)
reply(requests[3], { result = { { name = "书" }, { name = "二" } }, remaining = 0 })
Assert.len(result, 2)
Assert.eq(calls, 1)

reset()
replies = { { task = "task-1" }, { result = {}, remaining = 1 } }
handle = Client.searchAsync("书", done)
handle:cancel()
Stubs.flush()
Assert.len(requests, 2, "取消后不再调度下一次轮询")
Assert.eq(calls, 0)

reset()
replies = { { task = "task-1" } }
Client.searchAsync("书", done)
reply(requests[2], { result = {} })
Assert.is_nil(result)
Assert.eq(reason, "响应无效", "缺少 remaining 不能伪装成搜索完成")

reset()
replies = { { task = "task-1" } }
Client.searchAsync("书", done)
reply(requests[2], { result = { { name = "书" } }, remaining = 1 })
Stubs.flush()
requests[3].cb(nil, "network failed")
Assert.is_nil(result)
Assert.eq(reason, "network failed", "中途失败不能返回不完整搜索结果")
Assert.eq(calls, 1)

reset()
replies = { { task = "task-1" } }
for _index = 1, 30 do replies[#replies + 1] = { result = { { name = "书" } }, remaining = 1 } end
Client.searchAsync("书", done)
Stubs.flush()
Assert.is_nil(result)
Assert.eq(reason, "iRead 搜索超时，请重试")
Assert.eq(calls, 1)
Assert.len(requests, 31)

reset()
replies = { { task = "task-1" }, { result = {}, remaining = 1 } }
Client.searchAsync("书", done)
cfg.token = "new-token"
Stubs.flush()
Assert.len(requests, 2, "换登录态后不继续旧搜索任务")
Assert.eq(reason, "登录状态已变化，请重试")

reset()
replies = { {} }
handle = Client.saveProgressAsync({ name = "书" }, { index = 2, offset = 0 }, done)
pending = requests[2]
handle:cancel()
Assert.is_true(pending.cancelled)
reply(pending, { { name = "书", durChapterIndex = 2, durChapterPos = 0 } })
Assert.eq(calls, 0)

reset()
replies = { {}, { { name = "书", durChapterIndex = 1, durChapterPos = 0 } } }
Client.saveProgressAsync({ name = "书" }, { index = 2, offset = 0 }, done)
Assert.is_nil(result)
Assert.eq(reason, "iRead 阅读进度更新未生效")
Assert.eq(calls, 1)
